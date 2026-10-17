import BrimProcess
import Foundation
import os
import Synchronization

// swiftformat:disable wrapMultilineStatementBraces
/// Brim's administrator process, kept as small as possible: it runs as root,
/// so everything it can be talked into, it does as root. It links one small
/// module and holds no state.
private let log = Logger(subsystem: "com.sabharishhh.brim.jobhelper", category: "removal")

/// Runs the administrator process. The package executable and the copy in
/// the app bundle both just call this, so the code that runs as root is one
/// thing, covered by the package's tests.
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
                helper.disconnect { exit(75) }
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
    private let shutdownQueue = DispatchQueue(label: "com.sabharishhh.brim.helper-shutdown")

    init(requesterUID: uid_t? = nil) {
        self.requesterUID = requesterUID
        super.init()
    }

    // MARK: - What it will do

    var connectionCancelled: Bool {
        asyncJobs.withLock { $0.cancelled }
    }

    /// Cancellation stops owned commands first. A synchronous file operation
    /// cannot see task cancellation, so shutdown also has a deadline once Brim
    /// closes the connection.
    func disconnect(after gracePeriod: DispatchTimeInterval = .seconds(3),
                    terminate: @escaping @Sendable () -> Void) {
        let tasks = asyncJobs.withLock { jobs -> [Task<Void, Never>]? in
            guard !jobs.cancelled else { return nil }
            jobs.cancelled = true
            return Array(jobs.tasks.values)
        }
        guard let tasks else { return }
        for task in tasks {
            task.cancel()
        }
        // Commands get time to end and reap their children, but a stalled deletion
        // cannot keep this root process alive until the fifteen-minute session
        // limit. Shutdown never waits behind other work on the global queue.
        shutdownQueue.asyncAfter(deadline: .now() + gracePeriod, execute: terminate)
    }

    /// Registered before a disconnect can cancel, and the cancellation flag is
    /// kept so a request already read cannot start another job.
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
                defer { _ = asyncJobs.withLock { $0.tasks.removeValue(forKey: identifier) } }
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

    /// Removes the quarantine and Brim's privacy grants, and nothing else: the
    /// one place this deletes rather than sets aside. The path and identifier
    /// are constants in this binary, never parameters.
    func uninstallSelf(withReply reply: @escaping @Sendable (String?) -> Void) {
        // Full Disk Access is in the system privacy database, which only root can
        // change, and `tccutil` finds the app through Launch Services, so this runs
        // while the bundle is still on disk.
        Self.resetPrivacyGrants(of: BrimJobHelper.applicationIdentifier)
        let quarantine = URL(fileURLWithPath: BrimJobHelper.quarantineDirectory)
        let parent = quarantine.deletingLastPathComponent()
        do {
            if FileManager.default.fileExists(atPath: quarantine.path) {
                try FileManager.default.removeItem(at: quarantine)
            }
            // The parent is Brim's own folder, removed only if nothing else was in it.
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
               contents.isEmpty {
                try? FileManager.default.removeItem(at: parent)
            }
            log.info("removed the quarantine")
            reply(nil)
        } catch {
            log.error("could not remove the quarantine: \(error.localizedDescription)")
            reply("Administrator cleanup could not clear the folder it kept set-aside files in: "
                + error.localizedDescription)
        }
    }

    static func resetPrivacyGrants(of identifier: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "All", identifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("could not reset privacy grants: \(error.localizedDescription)")
        }
    }

    func removeDefunctJob(domain: String, name: String, withReply reply: @escaping @Sendable (String?) -> Void) {
        runJob(withReply: reply) { [self] in
            do {
                try Task.checkCancellation()
                let target = try PrivilegedJobRemoval.target(domain: domain, name: name)
                try await setAside(target, requesterUID: requesterUID)
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
        let itemName = packageID + "/" + name
        do {
            let target = try PrivilegedPayloadRemoval.target(packageID: packageID, name: name)
            try setAsideBundle(target)
            log.info("set aside \(target.path, privacy: .public)")
            reply(nil)
        } catch let refusal as PrivilegedPayloadRemoval.Refusal {
            log
                .error(
                    "refused \(itemName, privacy: .public): \(refusal.explanation, privacy: .public)"
                )
            reply(refusal.explanation)
        } catch let refusal as PrivilegedBundleRemoval.Refusal {
            log
                .error(
                    "refused \(itemName, privacy: .public): \(refusal.explanation, privacy: .public)"
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
}
