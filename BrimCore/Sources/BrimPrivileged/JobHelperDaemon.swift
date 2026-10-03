import BrimProcess
import Foundation
import os
import Synchronization

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
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--temporary" else {
            exit(64)
        }
        do {
            let connection = try TemporaryAdminChannel.connectToApp(path: CommandLine.arguments[2])
            runTemporary(descriptor: connection.descriptor, requesterUID: connection.requesterUID)
        } catch {
            log.error("administrator connection refused: \(error.localizedDescription, privacy: .public)")
            exit(77)
        }
    }

    private static func runTemporary(descriptor: Int32, requesterUID: uid_t) -> Never {
        let helper = Helper(requesterUID: requesterUID)
        let finished = DispatchSemaphore(value: 0)
        // An idle connection and an unfinished request both have a finite lifetime.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15 * 60) { exit(75) }
        let disconnect = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        disconnect.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        disconnect.setEventHandler {
            var state = pollfd(fd: descriptor, events: 0, revents: 0)
            if poll(&state, 1, 0) > 0, state.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                helper.cancelPendingJobs()
                _ = shutdown(descriptor, SHUT_RDWR)
            }
        }
        disconnect.resume()
        Task.detached {
            defer {
                TemporaryAdminChannel.close(descriptor)
                finished.signal()
            }
            do {
                while true {
                    let request = try TemporaryAdminChannel.receiveRequest(from: descriptor)
                    let response = await reply(to: request, using: helper)
                    try TemporaryAdminChannel.sendResponse(response, to: descriptor)
                }
            } catch {
                // EOF is the ordinary end of a selection, including app termination.
                log.info("administrator connection ended: \(error.localizedDescription, privacy: .public)")
            }
        }
        finished.wait()
        disconnect.cancel()
        exit(0)
    }

    private static func reply(to request: TemporaryAdminRequest, using helper: Helper) async -> TemporaryAdminResponse {
        guard !helper.connectionCancelled else {
            return TemporaryAdminResponse(complaint: "The administrator operation was cancelled.")
        }
        switch request {
        case .version:
            return TemporaryAdminResponse(data: Data(BrimJobHelper.version.utf8))
        case .recoveryItems:
            return await withCheckedContinuation { continuation in
                helper.recoveryItems { data, complaint in
                    continuation.resume(returning: TemporaryAdminResponse(data: data, complaint: complaint))
                }
            }
        default:
            return await withCheckedContinuation { continuation in
                let reply: @Sendable (String?) -> Void = { complaint in
                    continuation.resume(returning: TemporaryAdminResponse(complaint: complaint))
                }
                dispatchRemoval(request, using: helper, reply: reply)
            }
        }
    }

    private static func dispatchRemoval(
        _ request: TemporaryAdminRequest, using helper: Helper, reply: @escaping @Sendable (String?) -> Void
    ) {
        switch request {
        case let .removeDefunctJob(domain, name):
            helper.removeDefunctJob(domain: domain, name: name, withReply: reply)
        case let .removeBrokenCommand(domain, name):
            helper.removeBrokenCommand(domain: domain, name: name, withReply: reply)
        case let .forgetReceipt(packageID):
            helper.forgetReceipt(packageID: packageID, withReply: reply)
        case let .removeInstalledBundle(domain, name):
            helper.removeInstalledBundle(domain: domain, name: name, withReply: reply)
        case let .removeInstalledPayload(packageID, name):
            helper.removeInstalledPayload(packageID: packageID, name: name, withReply: reply)
        case let .removeSystemCache(name):
            helper.removeSystemCache(name: name, withReply: reply)
        case let .removeSystemPreference(name):
            helper.removeSystemPreference(name: name, withReply: reply)
        case let .removeRecoveryItem(identifier, device, inode):
            helper.removeRecoveryItem(identifier: identifier, expectedDevice: device,
                                      expectedInode: inode, withReply: reply)
        case .uninstallSelf:
            helper.uninstallSelf(withReply: reply)
        case .version, .recoveryItems:
            reply("The operation was not recognized.")
        }
    }
}

final class Helper: NSObject, BrimJobHelperProtocol, Sendable {
    private let requesterUID: uid_t?
    private struct AsyncJobs {
        var cancelled = false
        var tasks: [UUID: Task<Void, Never>] = [:]
    }

    private let asyncJobs = Mutex(AsyncJobs())

    init(requesterUID: uid_t? = nil) {
        self.requesterUID = requesterUID
        super.init()
    }

    // MARK: - What it will do

    var connectionCancelled: Bool {
        asyncJobs.withLock { $0.cancelled }
    }

    func cancelPendingJobs() {
        let tasks = asyncJobs.withLock { jobs in
            jobs.cancelled = true
            return Array(jobs.tasks.values)
        }
        for task in tasks {
            task.cancel()
        }
    }

    /// Register before a disconnect can cancel, and keep the cancellation
    /// flag so a request already read from the socket cannot start another job.
    private func runJob(
        withReply reply: @escaping @Sendable (String?) -> Void,
        operation: @escaping @Sendable () async -> Void
    ) {
        asyncJobs.withLock { jobs in
            guard !jobs.cancelled else {
                reply("The administrator operation was cancelled.")
                return
            }
            let identifier = UUID()
            jobs.tasks[identifier] = Task {
                defer { asyncJobs.withLock { $0.tasks.removeValue(forKey: identifier) } }
                await operation()
            }
        }
    }

    func forgetReceipt(packageID: String, withReply reply: @escaping @Sendable (String?) -> Void) {
        runJob(withReply: reply) { [self] in
            do {
                try Task.checkCancellation()
                try PrivilegedReceiptRemoval.check(packageID)
                try await qualifyReceiptPayload(packageID)
                try Task.checkCancellation()
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

    func recoveryItems(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        do {
            try reply(JSONEncoder().encode(PrivilegedRecoveryStore().items()), nil)
        } catch { reply(nil, error.localizedDescription) }
    }

    func removeRecoveryItem(
        identifier: String, expectedDevice: Int32, expectedInode: UInt64,
        withReply reply: @escaping @Sendable (String?) -> Void
    ) {
        do {
            try PrivilegedRecoveryStore().remove(
                identifier: identifier, expectedDevice: expectedDevice, expectedInode: expectedInode
            )
            reply(nil)
        } catch { reply(error.localizedDescription) }
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
        runJob(withReply: reply) { [self] in
            do {
                try Task.checkCancellation()
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
        let contents = try PrivilegedJobRemoval.readReviewedPlist(parent: parent, name: name, reviewed: info)

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

        try await stopDeclaredJob(contents, directory: directory, path: target.path, beforeStop: {
            try PrivilegedJobRemoval.validateReviewedEntry(parent: parent, name: name, reviewed: info)
        })
        try Task.checkCancellation()
        try PrivilegedJobRemoval.validateReviewedEntry(parent: parent, name: name, reviewed: info)
        try moveIntoQuarantine(parent: parent, name: name, from: directory)
    }

    private func stopDeclaredJob(
        _ contents: Data, directory: String, path: String, beforeStop: () throws -> Void
    ) async throws {
        if let dictionary = try? PropertyListSerialization.propertyList(
            from: contents, options: [], format: nil
        ) as? [String: Any], let label = dictionary["Label"] as? String {
            guard !label.isEmpty, !label.contains("/"), !label.contains("\0"),
                  !label.hasPrefix("com.apple."), let requesterUID, requesterUID != 0
            else {
                throw PrivilegedJobRemoval.Refusal.unreadable
            }
            let namespace = directory == "/Library/LaunchDaemons" ? "system" : "gui/\(requesterUID)"
            try await stopReviewedJob(label: label, namespace: namespace, path: path,
                                      contents: contents, beforeStop: beforeStop)
        } else {
            // Without a label no exact runtime check is possible. Preserve it.
            throw PrivilegedJobRemoval.Refusal.unreadable
        }
    }

    private func stopReviewedJob(
        label: String, namespace: String, path: String, contents: Data, beforeStop: () throws -> Void
    ) async throws {
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
        guard loaded.termination == .exited(0), !loaded.outputTruncated,
              PrivilegedJobRemoval.loadedJobMatchesReviewedDefinition(
                  String(data: loaded.stdout, encoding: .utf8) ?? "",
                  reviewedPath: path, reviewedPlist: contents
              ) else {
            throw PrivilegedJobRemoval.Refusal.unreadable
        }
        try beforeStop()
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
