import BrimProcess
import Foundation
import os

// swiftformat:disable wrapMultilineStatementBraces
/// Brim's privileged daemon, and deliberately almost nothing.
///
/// It runs as root, so every line here is worth more scrutiny than the
/// rest of the application put together. It links one small module, it
/// answers two questions, and it holds no state.
///
/// The previous attempt at a helper ran the whole of `BrimService` as
/// root. That is the wrong shape: a root process should be small enough to
/// read in one sitting, because anything it can be talked into doing, it
/// does as root.
private let log = Logger(subsystem: "com.sabharishhh.brim.jobhelper", category: "removal")

/// Runs the daemon. Both the package executable and the copy inside the
/// application bundle are two lines that call this, so the code that runs
/// as root is one thing, in one place, covered by the package's tests.
public enum BrimJobHelperDaemon {
    public static func run() -> Never {
        let helper = Helper()
        let listener = NSXPCListener(machServiceName: BrimJobHelper.machServiceName)
        listener.delegate = helper
        listener.resume()
        log.info("BrimJobHelper \(BrimJobHelper.version) listening")
        RunLoop.main.run()
        fatalError("the run loop returned, which it does not")
    }
}

final class Helper: NSObject, BrimJobHelperProtocol, NSXPCListenerDelegate, Sendable {
    private let requesterUID: uid_t?
    init(requesterUID: uid_t? = nil) {
        self.requesterUID = requesterUID
        super.init()
    }

    // MARK: - Who may speak to it

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // macOS invalidates the connection when the peer does not satisfy
        // this, which is the enforcement. The previous attempt set a
        // requirement naming the wrong application and the wrong team,
        // then returned true regardless, so it accepted everyone.
        //
        // Compiled first, because `setCodeSigningRequirement` raises on a
        // string it cannot parse rather than returning a failure, and a
        // root daemon crashing on an incoming connection is a worse
        // outcome than one refusing it.
        let requirement = BrimJobHelper.clientRequirement()
        guard BrimJobHelper.isWellFormed(requirement) else {
            log.error("refusing every connection: the client requirement will not compile")
            return false
        }
        connection.setCodeSigningRequirement(requirement)

        connection.exportedInterface = NSXPCInterface(with: BrimJobHelperProtocol.self)
        connection.exportedObject = Helper(requesterUID: connection.effectiveUserIdentifier)
        connection.resume()
        // Deliberately not logging the peer's pid. A pid is reused, so it
        // names the wrong process by the time anybody reads the log, and
        // the grep test that keeps pids out of authorisation decisions is
        // worth more than the detail.
        log.info("accepted a connection from a peer that satisfied the requirement")
        return true
    }

    // MARK: - What it will do

    func forgetReceipt(packageID: String, withReply reply: @escaping @Sendable (String?) -> Void) {
        Task {
            do {
                try PrivilegedReceiptRemoval.check(packageID)
                try await qualifyReceiptPayload(packageID)
                let status = try await runPkgutil(forgetting: packageID)
                guard status == 0 else {
                    throw PrivilegedReceiptRemoval.Refusal.pkgutilFailed(status)
                }
                log.info("forgot the receipt for \(packageID, privacy: .public)")
                reply(nil)
            } catch let refusal as PrivilegedReceiptRemoval.Refusal {
                log.error("refused \(packageID, privacy: .public): \(refusal.explanation, privacy: .public)")
                reply(refusal.explanation)
            } catch {
                log.error("failed \(packageID, privacy: .public): \(error.localizedDescription)")
                reply(error.localizedDescription)
            }
        }
    }

    private func qualifyReceiptPayload(_ packageID: String) async throws {
        let receipt = URL(fileURLWithPath: PrivilegedReceiptRemoval.receiptDirectory)
            .appendingPathComponent(packageID + ".plist")
        guard let data = try? Data(contentsOf: receipt),
              let metadata = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let prefix = metadata["InstallPrefixPath"] as? String else {
            throw PrivilegedReceiptRemoval.Refusal.payloadNotGone
        }
        let result = try await NativeCommandRunner.run(executable: "/usr/sbin/pkgutil",
                                                       arguments: ["--only-files", "--files", packageID],
                                                       environment: [
                                                           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                                                           "LANG": "C",
                                                           "LC_ALL": "C"
                                                       ], timeout: 10)
        guard result.termination == .exited(0), !result.outputTruncated,
              let listing = String(data: result.stdout, encoding: .utf8) else {
            throw PrivilegedReceiptRemoval.Refusal.payloadNotGone
        }
        try PrivilegedReceiptRemoval.checkPayload(listing: listing, prefix: prefix) { path in
            let components = URL(fileURLWithPath: path).pathComponents
            if components.count > 2, components[1] == "Volumes" {
                var mount = stat()
                guard lstat("/Volumes/" + components[2], &mount) == 0 else {
                    throw PrivilegedReceiptRemoval.Refusal.payloadNotGone
                }
            }
            var info = stat()
            if lstat(path, &info) == 0 {
                return true
            }
            let failure = errno
            guard failure == ENOENT || failure == ENOTDIR else {
                throw PrivilegedReceiptRemoval.Refusal.payloadNotGone
            }
            return false
        }
    }

    /// A fixed tool with fixed arguments. The package identifier has
    /// already been checked to contain nothing but identifier characters,
    /// and it is passed as an argument rather than through a shell.
    private func runPkgutil(forgetting packageID: String) async throws -> Int32 {
        let result = try await NativeCommandRunner.run(
            executable: "/usr/sbin/pkgutil", arguments: ["--forget", packageID],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"],
            timeout: 10
        )
        guard case let .exited(status) = result.termination else {
            throw NSError(domain: "BrimHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The installer record command did not finish."
            ])
        }
        return status
    }

    func version(withReply reply: @escaping @Sendable (String) -> Void) {
        reply(BrimJobHelper.version)
    }

    /// Removes the quarantine, and nothing else.
    ///
    /// The one place this daemon deletes rather than sets aside, because
    /// there is nowhere left to set anything aside to. The path is a
    /// constant in this binary, never a parameter, so the interface still
    /// cannot be talked into removing something else.
    func uninstallSelf(withReply reply: @escaping @Sendable (String?) -> Void) {
        let quarantine = URL(fileURLWithPath: BrimJobHelper.quarantineDirectory)
        guard FileManager.default.fileExists(atPath: quarantine.path) else {
            log.info("nothing to clean up on the way out")
            return reply(nil)
        }
        do {
            try FileManager.default.removeItem(at: quarantine)
            // The parent is Brim's own folder. Taken away only if Brim is
            // the only thing that was in it.
            let parent = quarantine.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
               contents.isEmpty {
                try? FileManager.default.removeItem(at: parent)
            }
            log.info("removed the quarantine")
            reply(nil)
        } catch {
            log.error("could not remove the quarantine: \(error.localizedDescription)")
            reply("Brim's helper could not clear the folder it kept set-aside files in: "
                + error.localizedDescription)
        }
    }

    func removeDefunctJob(domain: String, name: String, withReply reply: @escaping @Sendable (String?) -> Void) {
        Task {
            do {
                let target = try PrivilegedJobRemoval.target(domain: domain, name: name)
                try await setAside(target)
                log.info("set aside \(target.path, privacy: .public)")
                reply(nil)
            } catch let refusal as PrivilegedJobRemoval.Refusal {
                log.error("refused \(domain)/\(name, privacy: .public): \(refusal.explanation, privacy: .public)")
                reply(refusal.explanation)
            } catch {
                log.error("failed \(domain)/\(name, privacy: .public): \(error.localizedDescription)")
                reply(error.localizedDescription)
            }
        }
    }

    func removeInstalledBundle(domain: String, name: String, withReply reply: @escaping @Sendable (String?) -> Void) {
        do {
            let target = try PrivilegedBundleRemoval.target(domain: domain, name: name)
            try setAsideBundle(target)
            log.info("set aside \(target.path, privacy: .public)")
            reply(nil)
        } catch let refusal as PrivilegedBundleRemoval.Refusal {
            log.error("refused \(domain)/\(name, privacy: .public): \(refusal.explanation, privacy: .public)")
            reply(refusal.explanation)
        } catch {
            log.error("failed \(domain)/\(name, privacy: .public): \(error.localizedDescription)")
            reply(error.localizedDescription)
        }
    }

    func removeInstalledPayload(
        packageID: String,
        name: String,
        withReply reply: @escaping @Sendable (String?) -> Void
    ) {
        do {
            let target = try PrivilegedPayloadRemoval.target(packageID: packageID, name: name)
            try setAsideBundle(target)
            log.info("set aside \(target.path, privacy: .public)")
            reply(nil)
        } catch let refusal as PrivilegedPayloadRemoval.Refusal {
            log
                .error(
                    "refused \(packageID, privacy: .public)/\(name, privacy: .public): \(refusal.explanation, privacy: .public)"
                )
            reply(refusal.explanation)
        } catch let refusal as PrivilegedBundleRemoval.Refusal {
            log
                .error(
                    "refused \(packageID, privacy: .public)/\(name, privacy: .public): \(refusal.explanation, privacy: .public)"
                )
            reply(refusal.explanation)
        } catch {
            log.error("failed \(packageID, privacy: .public)/\(name, privacy: .public): \(error.localizedDescription)")
            reply(error.localizedDescription)
        }
    }

    func removeSystemCache(name: String, withReply reply: @escaping @Sendable (String?) -> Void) {
        do {
            let target = try PrivilegedCacheRemoval.target(name: name)
            try setAsideCache(target)
            log.info("set aside \(target.path, privacy: .public)")
            reply(nil)
        } catch let refusal as PrivilegedCacheRemoval.Refusal {
            log.error("refused cache \(name, privacy: .public): \(refusal.explanation, privacy: .public)")
            reply(refusal.explanation)
        } catch {
            log.error("failed cache \(name, privacy: .public): \(error.localizedDescription)")
            reply(error.localizedDescription)
        }
    }

    func removeSystemPreference(name: String, withReply reply: @escaping @Sendable (String?) -> Void) {
        do {
            let target = try PrivilegedPreferenceRemoval.target(name: name)
            try setAsidePreference(target)
            log.info("set aside \(target.path, privacy: .public)")
            reply(nil)
        } catch let refusal as PrivilegedPreferenceRemoval.Refusal {
            log.error("refused preference \(name, privacy: .public): \(refusal.explanation, privacy: .public)")
            reply(refusal.explanation)
        } catch {
            log.error("failed preference \(name, privacy: .public): \(error.localizedDescription)")
            reply(error.localizedDescription)
        }
    }

    func removeBrokenCommand(domain: String, name: String, withReply reply: @escaping @Sendable (String?) -> Void) {
        do {
            let target = try PrivilegedLinkRemoval.target(domain: domain, name: name)
            try setAsideDeadLink(target)
            log.info("set aside \(target.path, privacy: .public)")
            reply(nil)
        } catch let refusal as PrivilegedLinkRemoval.Refusal {
            log.error("refused \(domain)/\(name, privacy: .public): \(refusal.explanation, privacy: .public)")
            reply(refusal.explanation)
        } catch {
            log.error("failed \(domain)/\(name, privacy: .public): \(error.localizedDescription)")
            reply(error.localizedDescription)
        }
    }

    // MARK: - Doing it without being tricked

    /// Moves a dead command link into the quarantine, having proved it is
    /// dead through the directory's own descriptor.
    ///
    /// A rename where the volume allows one. Where it does not, the link is
    /// written again inside the quarantine with the same destination and
    /// then removed: a link is nothing but its destination, so that copy
    /// is exact and it still puts back.
    private func setAsideDeadLink(_ target: URL) throws {
        let directory = target.deletingLastPathComponent().path
        let name = target.lastPathComponent

        let parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw PrivilegedLinkRemoval.Refusal.notThere }
        defer { close(parent) }

        let destination = try PrivilegedLinkRemoval.deadDestination(parent: parent, name: name)
        let holding = try openHoldingFolder(for: directory) { why in
            PrivilegedLinkRemoval.Refusal.couldNotQuarantine(why)
        }
        defer { close(holding) }

        if renameat(parent, name, holding, name) == 0 {
            return
        }
        guard errno == EXDEV else {
            throw PrivilegedLinkRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
        guard symlinkat(destination, holding, name) == 0 else {
            throw PrivilegedLinkRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
        guard unlinkat(parent, name, 0) == 0 else {
            throw PrivilegedLinkRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
    }

    /// A fresh, dated folder in the quarantine, named after the folder the
    /// item came from, opened as a descriptor.
    private func openHoldingFolder(
        for directory: String, refusal: (String) -> Error
    ) throws -> Int32 {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = URL(fileURLWithPath: BrimJobHelper.quarantineDirectory)
            .appendingPathComponent(stamp)
            .appendingPathComponent((directory as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw refusal(error.localizedDescription)
        }
        let holding = open(destination.path, O_RDONLY | O_DIRECTORY)
        guard holding >= 0 else { throw refusal("the holding folder would not open") }
        return holding
    }

    /// Moves the job file into a root-owned quarantine, having checked
    /// that it is what it claims to be.
    ///
    /// Everything happens through a file descriptor for the directory,
    /// opened with `O_NOFOLLOW`, so a symlink swapped in between the check
    /// and the move cannot redirect it. That gap is the classic way a root
    /// helper is turned into a tool for deleting something else.
    private func setAside(_ target: URL) async throws {
        let directory = target.deletingLastPathComponent().path
        let name = target.lastPathComponent

        let parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw PrivilegedJobRemoval.Refusal.notThere }
        defer { close(parent) }

        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw PrivilegedJobRemoval.Refusal.notThere
        }
        // A symlink, a directory or a device is not a job file, whatever
        // it is called.
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw PrivilegedJobRemoval.Refusal.notARegularFile
        }
        guard info.st_size <= 64 * 1024 else {
            throw PrivilegedJobRemoval.Refusal.tooBigForAJobFile(Int(info.st_size))
        }

        // Read through the same descriptor, so what is judged is what is
        // moved.
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW)
        guard file >= 0 else { throw PrivilegedJobRemoval.Refusal.unreadable }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        guard let contents = try? handle.readToEnd() ?? Data() else {
            throw PrivilegedJobRemoval.Refusal.unreadable
        }

        // The rule that makes this safe to expose: a job that still runs
        // something present on this Mac is not a leftover and is never
        // removed, whoever is asking.
        guard PrivilegedJobRemoval.isDefunct(
            plist: contents,
            programExists: {
                var targetInfo = stat()
                if stat($0, &targetInfo) == 0 {
                    return true
                }
                let failure = errno
                return failure != ENOENT && failure != ENOTDIR
            }
        ) else {
            throw PrivilegedJobRemoval.Refusal.stillWorking
        }

        try await stopDeclaredJob(contents, directory: directory, path: target.path)
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == info.st_dev, current.st_ino == info.st_ino,
              current.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec
        else {
            throw PrivilegedJobRemoval.Refusal.unreadable
        }
        try moveIntoQuarantine(parent: parent, name: name, from: directory)
    }

    private func stopDeclaredJob(_ contents: Data, directory: String, path: String) async throws {
        if let dictionary = try? PropertyListSerialization.propertyList(
            from: contents, options: [], format: nil
        ) as? [String: Any], let label = dictionary["Label"] as? String {
            guard !label.isEmpty, !label.contains("/"), !label.contains("\0"),
                  !label.hasPrefix("com.apple."), let requesterUID, requesterUID != 0
            else {
                throw PrivilegedJobRemoval.Refusal.unreadable
            }
            let namespace = directory == "/Library/LaunchDaemons" ? "system" : "gui/\(requesterUID)"
            try await stopReviewedJob(label: label, namespace: namespace, path: path)
        } else {
            // Without a label no exact runtime check is possible. Preserve it.
            throw PrivilegedJobRemoval.Refusal.unreadable
        }
    }

    private func stopReviewedJob(label: String, namespace: String, path: String) async throws {
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        func query(_ target: String) async throws -> NativeCommandRunner.Result {
            try await NativeCommandRunner.run(executable: "/bin/launchctl", arguments: ["print", target],
                                              environment: environment, timeout: 5)
        }
        guard try await query(namespace).termination == .exited(0) else {
            throw PrivilegedJobRemoval.Refusal.unreadable
        }
        let service = namespace + "/" + label
        let loaded = try await query(service)
        let diagnostic = (String(data: loaded.stderr, encoding: .utf8) ?? "")
        if loaded.termination == .exited(113), !loaded.outputTruncated,
           diagnostic.contains("Could not find service") {
            return
        }
        let recordedPath = (String(data: loaded.stdout, encoding: .utf8) ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("path = ") }.map { String($0.dropFirst(7)) }
        guard loaded.termination == .exited(0), !loaded.outputTruncated, recordedPath == path else {
            throw PrivilegedJobRemoval.Refusal.unreadable
        }
        let stopped = try await NativeCommandRunner.run(executable: "/bin/launchctl", arguments: ["bootout", service],
                                                        environment: environment, timeout: 5)
        guard stopped.termination == .exited(0) else { throw PrivilegedJobRemoval.Refusal.stillWorking }
        let after = try await query(service)
        guard after.termination == .exited(113), !after.outputTruncated,
              (String(data: after.stderr, encoding: .utf8) ?? "").contains("Could not find service")
        else {
            throw PrivilegedJobRemoval.Refusal.stillWorking
        }
    }

    /// Renames the file into the quarantine rather than unlinking it, so a
    /// mistake can be undone. Both directories are on the same volume, so
    /// this is one atomic rename and never a partial copy.
    /// Judged and moved through one descriptor for the folder, so a link
    /// swapped in after the check is not what moves.
    private func setAsideBundle(_ target: URL) throws {
        let directory = target.deletingLastPathComponent().path
        let name = target.lastPathComponent
        let parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw PrivilegedBundleRemoval.Refusal.notThere }
        defer { close(parent) }

        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw PrivilegedBundleRemoval.Refusal.notThere
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw PrivilegedBundleRemoval.Refusal.notAFolder }
        try PrivilegedBundleRemoval.check(bundle: target)

        let holding = try openHoldingFolder(for: directory) { why in
            PrivilegedBundleRemoval.Refusal.couldNotQuarantine(why)
        }
        defer { close(holding) }
        guard renameat(parent, name, holding, name) == 0 else {
            throw PrivilegedBundleRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
    }

    /// A folder or a file, never a link, moved through the directory's own
    /// descriptor so nothing can be swapped in between the look and the move.
    private func setAsideCache(_ target: URL) throws {
        let directory = target.deletingLastPathComponent().path
        let name = target.lastPathComponent
        let parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw PrivilegedCacheRemoval.Refusal.notThere }
        defer { close(parent) }

        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw PrivilegedCacheRemoval.Refusal.notThere
        }
        let type = info.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG else { throw PrivilegedCacheRemoval.Refusal.isALink }

        let holding = try openHoldingFolder(for: directory) { why in
            PrivilegedCacheRemoval.Refusal.couldNotQuarantine(why)
        }
        defer { close(holding) }
        guard renameat(parent, name, holding, name) == 0 else {
            throw PrivilegedCacheRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
    }

    /// A regular file only, moved through the directory's own descriptor.
    private func setAsidePreference(_ target: URL) throws {
        let directory = target.deletingLastPathComponent().path
        let name = target.lastPathComponent
        let parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw PrivilegedPreferenceRemoval.Refusal.notThere }
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw PrivilegedPreferenceRemoval.Refusal.notThere
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw PrivilegedPreferenceRemoval.Refusal.notAFile }
        let holding = try openHoldingFolder(for: directory) { why in
            PrivilegedPreferenceRemoval.Refusal.couldNotQuarantine(why)
        }
        defer { close(holding) }
        guard renameat(parent, name, holding, name) == 0 else {
            throw PrivilegedPreferenceRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
    }

    private func moveIntoQuarantine(parent: Int32, name: String, from directory: String) throws {
        let holding = try openHoldingFolder(for: directory) { why in
            PrivilegedJobRemoval.Refusal.couldNotQuarantine(why)
        }
        defer { close(holding) }

        guard renameat(parent, name, holding, name) == 0 else {
            throw PrivilegedJobRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
    }
}
