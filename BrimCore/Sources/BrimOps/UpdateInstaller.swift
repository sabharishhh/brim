import AppKit
import BrimCore
import CryptoKit
import Foundation
import Security

/// Puts a newer version of an application in place of the installed one.
///
/// The installed copy is the trust anchor, as it is for Sparkle's own
/// installer: the download has to match what its source published, and the
/// application inside has to satisfy the installed application's designated
/// requirement, which names its identifier and its developer. So a catalogue
/// entry or a feed that pointed somewhere else could at worst offer an
/// application that is refused here. It also has to pass Gatekeeper, be
/// newer, and run on this Mac, and all of that is settled before the
/// installed application is asked to quit.
public struct UpdateInstaller: Sendable {
    public typealias Progress = @Sendable (Double) -> Void
    /// Moves something only root can move, as the helper does for removals.
    public typealias PrivilegedRemover = @Sendable (String) async -> String?

    public enum Failure: Error, Equatable, LocalizedError {
        case download(String)
        case integrity
        case unpack
        case noApplication
        case differentApplication
        case notSignedBySameDeveloper
        case gatekeeper
        case needsNewerMacOS(String)
        case wrongArchitecture
        case installedIsUnsigned
        case replace(String)
        case packageNotSignedBySameDeveloper

        public var errorDescription: String? {
            switch self {
            case .download(let why): return "The download failed: \(why)"
            case .integrity: return "The download does not match what its source published."
            case .unpack: return "The download could not be opened."
            case .noApplication, .differentApplication: return "The download does not contain this app."
            case .notSignedBySameDeveloper: return "The new version is not signed by the same developer."
            case .gatekeeper: return "macOS does not trust the new version."
            case .needsNewerMacOS(let version): return "The new version needs macOS \(version)."
            case .wrongArchitecture: return "The new version does not run on this Mac."
            case .installedIsUnsigned: return "The installed app is not signed, so the new version cannot be checked against it."
            case .replace(let why): return why
            case .packageNotSignedBySameDeveloper: return "The installer package is not signed by the app's developer."
            }
        }
    }

    private let workspace: URL
    private let remover: PrivilegedRemover?

    public init(workspace: URL, remover: PrivilegedRemover? = nil) {
        self.workspace = workspace
        self.remover = remover
    }

    public func install(_ update: AppUpdate, progress: @escaping Progress = { _ in }) async -> UpdateOutcome {
        let folder = workspace.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            guard let download = update.download else { return .failed("There is no download for this update.") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = try await Downloader.fetch(download.url, into: folder, progress: progress)
            guard try Self.matches(file, download.integrity) else { throw Failure.integrity }

            if update.route == .installer || Self.kind(of: file) == .package {
                try Self.checkPackage(file, against: update.appURL)
                let opened = await MainActor.run { NSWorkspace.shared.open(Self.keep(file, in: workspace)) }
                return opened ? .openedInstaller : .failed("Installer could not be opened.")
            }

            let unpacked = folder.appendingPathComponent("unpacked")
            let candidate = try Self.unpack(file, into: unpacked, bundleID: update.bundleID)
            if let refusal = try Self.verify(candidate, replacing: update.appURL) { return refusal }
            return try await replace(update.appURL, with: candidate)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Integrity

    public static func matches(_ file: URL, _ integrity: UpdateDownload.Integrity) throws -> Bool {
        switch integrity {
        case .none:
            return true
        case .sha256(let hex):
            return try digest(of: file, using: SHA256.self).hex == hex.lowercased()
        case .sha512(let base64):
            return try digest(of: file, using: SHA512.self).base64EncodedString() == base64
        case .edDSA(let signature, let key):
            guard let keyData = Data(base64Encoded: key), let signed = Data(base64Encoded: signature),
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
            else { return false }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            return publicKey.isValidSignature(signed, for: data)
        }
    }

    private static func digest<H: HashFunction>(of file: URL, using: H.Type) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = H()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    // MARK: - Unpacking

    enum Kind { case zip, diskImage, tar, package, unknown }

    /// By content, not by name: Visual Studio Code's download is called
    /// `stable`.
    static func kind(of file: URL) -> Kind {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .unknown }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 512)) ?? Data()
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if head.starts(with: Array("xar!".utf8)) { return .package }
        if head.starts(with: [0x1F, 0x8B]) || head.starts(with: Array("BZh".utf8))
            || head.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A]) { return .tar }
        if let end = try? handle.seekToEnd(), end >= 512 {
            try? handle.seek(toOffset: end - 512)
            if let trailer = try? handle.read(upToCount: 4), trailer == Data("koly".utf8) { return .diskImage }
        }
        return .unknown
    }

    static func unpack(_ file: URL, into folder: URL, bundleID: String, depth: Int = 0) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch kind(of: file) {
        case .zip:
            guard run("/usr/bin/ditto", ["-x", "-k", file.path, folder.path]) else { throw Failure.unpack }
        case .tar:
            guard run("/usr/bin/tar", ["-xf", file.path, "-C", folder.path]) else { throw Failure.unpack }
        case .diskImage:
            let mount = folder.deletingLastPathComponent().appendingPathComponent("mount-\(depth)")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            // A licence agreement asks on standard input before mounting.
            guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify",
                                           "-mountpoint", mount.path, file.path], input: "Y\n")
            else { throw Failure.unpack }
            defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            guard let app = find(bundleID, in: mount) else { throw Failure.noApplication }
            let copy = folder.appendingPathComponent(app.lastPathComponent)
            guard run("/usr/bin/ditto", [app.path, copy.path]) else { throw Failure.unpack }
            return copy
        case .package, .unknown:
            throw Failure.unpack
        }
        if let app = find(bundleID, in: folder) { return app }
        // A disk image inside a zip, as some vendors ship it.
        if depth == 0, let inner = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { ["dmg", "zip"].contains($0.pathExtension.lowercased()) }) {
            return try unpack(inner, into: folder.appendingPathComponent("inner"), bundleID: bundleID, depth: 1)
        }
        throw Failure.noApplication
    }

    /// The application with this identifier, within a few levels.
    static func find(_ bundleID: String, in folder: URL) -> URL? {
        var queue = [(folder, 0)]
        while !queue.isEmpty {
            let (directory, level) = queue.removeFirst()
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for entry in entries.sorted() {
                let url = directory.appendingPathComponent(entry)
                if entry.hasSuffix(".app") {
                    if identifier(of: url)?.lowercased() == bundleID.lowercased() { return url }
                } else if level < 3, !entry.hasPrefix("."), isFolder(url) {
                    queue.append((url, level + 1))
                }
            }
        }
        return nil
    }

    // MARK: - Checking

    /// Nil when the candidate may replace the installed application. An
    /// outcome when it is not needed, and an error when it is refused.
    static func verify(_ candidate: URL, replacing installed: URL) throws -> UpdateOutcome? {
        guard identifier(of: candidate)?.lowercased() == identifier(of: installed)?.lowercased() else {
            throw Failure.differentApplication
        }
        try satisfiesDesignatedRequirement(candidate, of: installed)
        guard isNewer(candidate, than: installed) else { return .alreadyCurrent }
        let info = NSDictionary(contentsOf: candidate.appendingPathComponent("Contents/Info.plist"))
        if let minimum = info?["LSMinimumSystemVersion"] as? String,
           !UpdatePlatformCheck.canRun(minimum: minimum) {
            throw Failure.needsNewerMacOS(minimum)
        }
        let architectures = Bundle(url: candidate)?.executableArchitectures?.map(\.intValue) ?? []
        #if arch(arm64)
        let runnable = architectures.contains(NSBundleExecutableArchitectureARM64)
            || architectures.contains(NSBundleExecutableArchitectureX86_64)
        #else
        let runnable = architectures.contains(NSBundleExecutableArchitectureX86_64)
        #endif
        guard architectures.isEmpty || runnable else { throw Failure.wrongArchitecture }
        guard passesGatekeeper(candidate) else { throw Failure.gatekeeper }
        return nil
    }

    static func satisfiesDesignatedRequirement(_ candidate: URL, of installed: URL) throws {
        var installedCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(installed as CFURL, [], &installedCode) == errSecSuccess,
              let installedCode,
              teamIdentifier(of: installed) != nil,
              SecCodeCopyDesignatedRequirement(installedCode, [], &requirement) == errSecSuccess,
              let requirement
        else { throw Failure.installedIsUnsigned }
        var candidateCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess,
              let candidateCode,
              SecStaticCodeCheckValidityWithErrors(
                  candidateCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode),
                  requirement, nil) == errSecSuccess
        else { throw Failure.notSignedBySameDeveloper }
    }

    /// `spctl` is Gatekeeper's own assessment, notarization included; the
    /// API behind it is not available to Swift.
    static func passesGatekeeper(_ candidate: URL, type: String = "execute") -> Bool {
        run("/usr/sbin/spctl", ["--assess", "--type", type, candidate.path])
    }

    static func teamIdentifier(of bundle: URL) -> String? {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess
        else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func isNewer(_ candidate: URL, than installed: URL) -> Bool {
        let new = NSDictionary(contentsOf: candidate.appendingPathComponent("Contents/Info.plist"))
        let old = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            guard let a = new?[key] as? String, let b = old?[key] as? String else { continue }
            switch VersionOrder.compare(a, b) {
            case .orderedDescending: return true
            case .orderedAscending: return false
            case .orderedSame: continue
            }
        }
        return false
    }

    /// An installer package is opened only when its signature names the
    /// application's own developer and Gatekeeper accepts it.
    static func checkPackage(_ package: URL, against installed: URL) throws {
        guard let team = teamIdentifier(of: installed),
              let output = runOutput("/usr/sbin/pkgutil", ["--check-signature", package.path]),
              output.contains("Developer ID Installer:"), output.contains("(\(team))")
        else { throw Failure.packageNotSignedBySameDeveloper }
        guard passesGatekeeper(package, type: "install") else { throw Failure.gatekeeper }
    }

    // MARK: - Replacing

    private func replace(_ installed: URL, with candidate: URL) async throws -> UpdateOutcome {
        let bundleID = Self.identifier(of: installed) ?? ""
        let wasRunning = await MainActor.run { Self.running(bundleID, at: installed) }
        if !wasRunning.isEmpty {
            await MainActor.run { wasRunning.forEach { $0.terminate() } }
            for _ in 0..<30 where await MainActor.run(body: { wasRunning.contains { !$0.isTerminated } }) {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            if await MainActor.run(body: { wasRunning.contains { !$0.isTerminated } }) {
                return .stillOpen(name: installed.deletingPathExtension().lastPathComponent)
            }
        }

        // Staged beside the old copy, so the last step is a rename on one
        // volume and the app is never missing for longer than that.
        let folder = installed.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(".\(UUID().uuidString)-\(installed.lastPathComponent)")
        do {
            try FileManager.default.moveItem(at: candidate, to: staged)
        } catch {
            throw Failure.replace(Self.permissionSentence(error, folder: folder))
        }
        var cleanUp = true
        defer { if cleanUp { try? FileManager.default.removeItem(at: staged) } }

        var info = stat()
        guard lstat(installed.path, &info) == 0 else { throw Failure.replace("The installed app is not there any more.") }
        do {
            _ = try SafeOps.trashItem(targetPath: installed.path, expectedDev: info.st_dev, expectedIno: info.st_ino)
        } catch {
            // An installer left it owned by root; the helper sets it aside.
            guard let remover, await remover(installed.path) == nil else {
                throw Failure.replace(Self.permissionSentence(error, folder: folder))
            }
        }
        do {
            try FileManager.default.moveItem(at: staged, to: installed)
            cleanUp = false
        } catch {
            throw Failure.replace("The old version is in the Trash, and the new one could not be put in its "
                                  + "place: \(error.localizedDescription)")
        }
        _ = Self.run("/usr/bin/xattr", ["-d", "-r", "com.apple.quarantine", installed.path])
        LSRegisterURL(installed as CFURL, true)
        if !wasRunning.isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: installed, configuration: configuration)
        }
        let version = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?[
            "CFBundleShortVersionString"] as? String ?? ""
        return .installed(version: version)
    }

    @MainActor
    private static func running(_ bundleID: String, at bundle: URL) -> [NSRunningApplication] {
        let path = bundle.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.filter { app in
            app.bundleIdentifier == bundleID
                || (app.bundleURL?.resolvingSymlinksInPath().path).map { $0 == path || $0.hasPrefix(path + "/") } == true
        }
    }

    /// macOS asks for App Management before one developer's app replaces
    /// another's, and says nothing to the app that was refused.
    static func permissionSentence(_ error: Error, folder: URL) -> String {
        let code = (error as NSError).code
        guard [NSFileWriteNoPermissionError, NSFileReadNoPermissionError, Int(EPERM), Int(EACCES)].contains(code)
                || ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EPERM)
        else { return error.localizedDescription }
        return "macOS did not let Brim change \(folder.lastPathComponent). Allow Brim in System Settings, "
            + "Privacy & Security, App Management."
    }

    // MARK: - Small things

    static func identifier(of bundle: URL) -> String? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
    }

    static func isFolder(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// Moves a package out of the folder that is cleaned up, so Installer
    /// can still read it.
    static func keep(_ file: URL, in workspace: URL) -> URL {
        let kept = workspace.appendingPathComponent("Packages", isDirectory: true)
        try? FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        let destination = kept.appendingPathComponent(file.pathExtension.isEmpty ? file.lastPathComponent + ".pkg"
                                                                                  : file.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], input: String? = nil) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        if input != nil { process.standardInput = pipe }
        guard (try? process.run()) != nil else { return false }
        if let input { pipe.fileHandleForWriting.write(Data(input.utf8)); try? pipe.fileHandleForWriting.close() }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func runOutput(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

/// This Mac's version, compared the way feeds write it.
enum UpdatePlatformCheck {
    static func canRun(minimum: String) -> Bool {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let current = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        return VersionOrder.compare(minimum, current) != .orderedDescending
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// A download with progress, into a folder Brim owns.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: UpdateInstaller.Progress
    private let folder: URL
    private var continuation: CheckedContinuation<URL, Error>?

    private init(folder: URL, progress: @escaping UpdateInstaller.Progress) {
        self.folder = folder
        self.progress = progress
    }

    static func fetch(_ url: URL, into folder: URL, progress: @escaping UpdateInstaller.Progress) async throws -> URL {
        guard url.scheme == "https" else { throw UpdateInstaller.Failure.download("It is not an HTTPS address.") }
        let downloader = Downloader(folder: folder, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            downloader.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            continuation?.resume(throwing: UpdateInstaller.Failure.download("The server answered \(status)."))
            continuation = nil
            return
        }
        let name = downloadTask.response?.suggestedFilename ?? "download"
        let destination = folder.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: UpdateInstaller.Failure.download(error.localizedDescription))
        continuation = nil
    }
}
