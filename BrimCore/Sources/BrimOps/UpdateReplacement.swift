import AppKit
import BrimCore
import Foundation

extension UpdateInstaller {
    // MARK: - Replacing

    static func replace(
        _ installed: URL, with candidate: URL, workspace: URL, remover: PrivilegedRemover?
    ) async throws -> UpdateOutcome {
        let bundleID = Self.identifier(of: installed) ?? ""
        let wasRunning = await MainActor.run { Self.running(bundleID, at: installed) }
        if !wasRunning.isEmpty {
            await MainActor.run { wasRunning.forEach { $0.terminate() } }
            for _ in 0 ..< 30 where await MainActor.run(body: { wasRunning.contains { !$0.isTerminated } }) {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            if await MainActor.run(body: { wasRunning.contains { !$0.isTerminated } }) {
                return .stillOpen(name: installed.deletingPathExtension().lastPathComponent)
            }
        }

        // Staged beside the old copy, and exchanged with it in one atomic
        // rename, so the app is always there: old, or new, never neither.
        // The intent is written first, so an update cut off by a quit, a
        // crash or a power cut is settled the next time Brim looks.
        let folder = installed.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(".\(UUID().uuidString)-\(installed.lastPathComponent)")
        do {
            try FileManager.default.moveItem(at: candidate, to: staged)
        } catch {
            throw Self.refusal(error, folder: folder)
        }
        let intent = Intent(installed: installed.path, staged: staged.path, version: Self.shortVersion(of: staged),
                            pid: getpid())
        let intentFile = try intent.write(in: workspace)
        defer { try? FileManager.default.removeItem(at: intentFile) }

        if renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) == 0 {
            // The old version is now at the staged path, and the new one is
            // in, so the old one is deleted.
            Self.removeOldVersion(staged)
        } else {
            let swapError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
            try await replaceWithoutExchange(
                installed, staged: staged, folder: folder, remover: remover, swapError: swapError
            )
        }
        _ = Self.run("/usr/bin/xattr", ["-d", "-r", "com.apple.quarantine", installed.path])
        LSRegisterURL(installed as CFURL, true)
        if !wasRunning.isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: installed, configuration: configuration)
        }
        return .installed(version: Self.shortVersion(of: installed))
    }

    private static func replaceWithoutExchange(
        _ installed: URL, staged: URL, folder: URL, remover: PrivilegedRemover?, swapError: POSIXError
    ) async throws {
        // A folder an installer left owned by root cannot be exchanged.
        // The old copy is set aside first, as before.
        var cleanUp = true
        defer {
            if cleanUp {
                try? FileManager.default.removeItem(at: staged)
            }
        }
        var info = stat()
        guard lstat(installed.path, &info) == 0 else {
            throw Failure.replace("The installed app is not there any more.")
        }
        do {
            _ = try SafeOps.trashItem(
                targetPath: installed.path, expectedDev: info.st_dev, expectedIno: info.st_ino
            )
        } catch {
            guard let remover, await remover(installed.path) == nil else {
                throw Self.refusal(swapError, folder: folder)
            }
        }
        do {
            try FileManager.default.moveItem(at: staged, to: installed)
            cleanUp = false
        } catch {
            // Left in place for recovery to finish rather than removed.
            cleanUp = false
            throw Failure.replace("The new version could not be put in place: \(error.localizedDescription)")
        }
    }

    /// Deletes the version an update replaced. It used to go to the Trash,
    /// where a 1.6 GB copy of an app sat until someone emptied it, to keep
    /// a rollback nobody was offered. If something inside cannot be
    /// deleted, an installer having left it owned by root, what remains
    /// goes to the Trash rather than staying hidden beside the new version.
    static func removeOldVersion(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        guard (try? FileManager.default.removeItem(at: url)) == nil else { return }
        guard lstat(url.path, &info) == 0 else { return }
        _ = try? SafeOps.trashItem(targetPath: url.path, expectedDev: info.st_dev, expectedIno: info.st_ino)
    }

    public static func shortVersion(of bundle: URL) -> String {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?[
            "CFBundleShortVersionString"
        ] as? String ?? ""
    }

    // MARK: - Recovery

    /// What an update was doing when it began swapping, so a run that was
    /// cut off can be finished or undone later.
    struct Intent: Codable {
        let installed: String
        let staged: String
        let version: String
        let pid: Int32

        func write(in workspace: URL) throws -> URL {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let file = workspace.appendingPathComponent("intent-\(UUID().uuidString).json")
            try JSONEncoder().encode(self).write(to: file, options: .atomic)
            return file
        }
    }

    /// Settles updates another run of Brim left unfinished, and clears the
    /// downloads it left. Returns, for each application whose update did
    /// not finish, why, keyed by its path.
    ///
    /// - The app is there and the staged copy too: the exchange either
    ///   never happened, and the staged copy is the unused download, or it
    ///   did, and the staged copy is the old version. Either way the staged
    ///   copy is deleted.
    /// - The app is missing and the staged copy is there: the old version
    ///   went to the Trash and the new one never moved in. The new one,
    ///   already checked, is moved into place.
    @discardableResult
    public static func recoverInterrupted(in workspace: URL) -> [String: String] {
        let manager = FileManager.default
        let current = getpid()
        var interrupted: [String: String] = [:]
        let entries = (try? manager.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)) ?? []
        for file in entries where file.lastPathComponent.hasPrefix("intent-") {
            guard let data = try? Data(contentsOf: file),
                  let intent = try? JSONDecoder().decode(Intent.self, from: data), intent.pid != current
            else { continue }
            let installed = URL(fileURLWithPath: intent.installed)
            let staged = URL(fileURLWithPath: intent.staged)
            // Only a staged copy Brim made, beside the app it was for.
            guard staged.deletingLastPathComponent() == installed.deletingLastPathComponent(),
                  staged.lastPathComponent.hasPrefix("."),
                  staged.lastPathComponent.hasSuffix("-" + installed.lastPathComponent)
            else { try? manager.removeItem(at: file); continue }
            let stagedExists = manager.fileExists(atPath: staged.path)
            if manager.fileExists(atPath: installed.path) {
                if stagedExists {
                    if shortVersion(of: installed) == intent.version {
                        removeOldVersion(staged)
                    } else {
                        try? manager.removeItem(at: staged)
                        interrupted[installed.path] = "Interrupted"
                    }
                } else if shortVersion(of: installed) != intent.version {
                    interrupted[installed.path] = "Interrupted"
                }
            } else if stagedExists, (try? manager.moveItem(at: staged, to: installed)) != nil {
                LSRegisterURL(installed as CFURL, true)
            } else {
                interrupted[installed.path] = "Interrupted. The old version is in the Trash."
            }
            try? manager.removeItem(at: file)
        }
        // Downloads another run left behind.
        for folder in entries where folder.lastPathComponent.first?.isNumber == true {
            let owner = folder.lastPathComponent.split(separator: "-").first.flatMap { Int32($0) }
            if owner != current {
                try? manager.removeItem(at: folder)
            }
        }
        clearPackages(in: workspace, installerIsOpen: isInstallerOpen())
        // Stopped downloads kept for resuming, once they are a day old.
        UpdateDownloader.discardExpired(in: workspace.appendingPathComponent("Resume"))
        ReadyDownloads.discardExpired(in: workspace)
        return interrupted
    }

    /// Packages are kept after an update only so Installer can read them.
    /// Once it has quit they are finished with, and were never cleared:
    /// every update that went through Installer left its package behind.
    static func clearPackages(in workspace: URL, installerIsOpen: Bool) {
        guard !installerIsOpen else { return }
        try? FileManager.default.removeItem(at: workspace.appendingPathComponent("Packages", isDirectory: true))
    }

    private static func isInstallerOpen() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.installer").isEmpty
    }

    @MainActor
    private static func running(_ bundleID: String, at bundle: URL) -> [NSRunningApplication] {
        let path = bundle.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.filter { app in
            if app.bundleIdentifier == bundleID {
                return true
            }
            guard let appPath = app.bundleURL?.resolvingSymlinksInPath().path else { return false }
            return appPath == path || appPath.hasPrefix(path + "/")
        }
    }
}
