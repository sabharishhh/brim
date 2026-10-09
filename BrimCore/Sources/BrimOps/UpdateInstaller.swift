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
    public typealias Progress = @Sendable (DownloadProgress) -> Void
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
        /// macOS refused to let Brim change the folder the app is in.
        case notAllowed(folder: String)

        public var errorDescription: String? {
            switch self {
            case let .download(why): "The download failed: \(why)"
            case .integrity: "The download does not match what its source published."
            case .unpack: "The download could not be opened."
            case .noApplication, .differentApplication: "The download does not contain this app."
            case .notSignedBySameDeveloper: "The new version is not signed by the same developer."
            case .gatekeeper: "macOS does not trust the new version."
            case let .needsNewerMacOS(version): "The new version needs macOS \(version)."
            case .wrongArchitecture: "The new version does not run on this Mac."
            case .installedIsUnsigned:
                "The installed app is not signed, so the new version cannot be checked against it."
            case let .replace(why): why
            case .packageNotSignedBySameDeveloper: "The installer package is not signed by the app's developer."
            case let .notAllowed(folder):
                "macOS did not let Brim change \(folder). Allow Brim in System Settings, "
                    + "Privacy & Security, App Management."
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
        // Named for this process, so recovery can tell a folder another
        // run left behind from one in use now.
        let folder = workspace.appendingPathComponent("\(getpid())-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            guard let download = update.download else { return .failed("There is no download for this update.") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = try await UpdateDownloader.fetch(
                download.url, into: folder, resumeFolder: workspace.appendingPathComponent("Resume"),
                progress: progress
            )
            guard try Self.matches(file, download.integrity) else { throw Failure.integrity }

            if update.route == .installer || Self.kind(of: file) == .package {
                try Self.checkPackage(file, against: update.appURL)
                let opened = await MainActor.run { NSWorkspace.shared.open(Self.keep(file, in: workspace)) }
                return opened ? .openedInstaller : .failed("Installer could not be opened.")
            }

            let unpacked = folder.appendingPathComponent("unpacked")
            let candidate = try Self.unpack(file, into: unpacked, bundleID: update.bundleID)
            if let refusal = try Self.verify(candidate, replacing: update.appURL) {
                return refusal
            }
            return try await replace(update.appURL, with: candidate)
        } catch let Failure.notAllowed(folder) {
            return .notAllowed(folder: folder)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Integrity

    public static func matches(_ file: URL, _ integrity: UpdateDownload.Integrity) throws -> Bool {
        switch integrity {
        case .none:
            return true
        case let .sha256(hex):
            return try digest(of: file, using: SHA256.self).hex == hex.lowercased()
        case let .sha512(base64):
            return try digest(of: file, using: SHA512.self).base64EncodedString() == base64
        case let .edDSA(signature, key):
            guard let keyData = Data(base64Encoded: key), let signed = Data(base64Encoded: signature),
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
            else { return false }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            return publicKey.isValidSignature(signed, for: data)
        }
    }

    private static func digest<H: HashFunction>(of file: URL, using _: H.Type) throws -> Data {
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
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return .zip
        }
        if head.starts(with: Array("xar!".utf8)) {
            return .package
        }
        let compressed = head.starts(with: [0x1F, 0x8B]) || head.starts(with: Array("BZh".utf8))
            || head.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A])
        if compressed {
            return .tar
        }
        if let end = try? handle.seekToEnd(), end >= 512 {
            try? handle.seek(toOffset: end - 512)
            if let trailer = try? handle.read(upToCount: 4), trailer == Data("koly".utf8) {
                return .diskImage
            }
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
            return try unpackDiskImage(file, into: folder, bundleID: bundleID, depth: depth)
        case .package, .unknown:
            throw Failure.unpack
        }
        if let app = find(bundleID, in: folder) {
            return app
        }
        // A disk image inside a zip, as some vendors ship it.
        if depth == 0, let inner = nestedArchive(in: folder) {
            return try unpack(inner, into: folder.appendingPathComponent("inner"), bundleID: bundleID, depth: 1)
        }
        throw Failure.noApplication
    }

    private static func nestedArchive(in folder: URL) -> URL? {
        FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { ["dmg", "zip"].contains($0.pathExtension.lowercased()) }
    }

    private static func unpackDiskImage(_ file: URL, into folder: URL, bundleID: String, depth: Int) throws -> URL {
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
                    if identifier(of: url)?.lowercased() == bundleID.lowercased() {
                        return url
                    }
                } else if level < 3, !entry.hasPrefix("."), isFolder(url) {
                    queue.append((url, level + 1))
                }
            }
        }
        return nil
    }

    private func replace(_ installed: URL, with candidate: URL) async throws -> UpdateOutcome {
        try await Self.replace(installed, with: candidate, workspace: workspace, remover: remover)
    }

    /// macOS asks for App Management before one developer's app replaces
    /// another's, and says nothing to the app that was refused. Full Disk
    /// Access covered it on macOS 27 when VS Code was updated, so Brim does
    /// not ask up front; a refusal is its own outcome, and the row offers
    /// the setting rather than a sentence about it.
    static func refusal(_ error: Error, folder: URL) -> Failure {
        let code = (error as NSError).code
        guard [NSFileWriteNoPermissionError, NSFileReadNoPermissionError, Int(EPERM), Int(EACCES)].contains(code)
            || ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EPERM)
        else { return .replace(error.localizedDescription) }
        return .notAllowed(folder: folder.lastPathComponent)
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
        if input != nil {
            process.standardInput = pipe
        }
        guard (try? process.run()) != nil else { return false }
        if let input {
            pipe.fileHandleForWriting.write(Data(input.utf8)); try? pipe.fileHandleForWriting.close()
        }
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

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
