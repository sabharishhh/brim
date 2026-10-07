import BrimProcess
import Foundation

/// Protected operations share one authenticated process for a selected batch.
/// Reading availability starts no process and registers no service.
@MainActor
public final class PrivilegedHelperClient: ObservableObject {
    public enum State: Equatable, Sendable {
        case notAsked, ready
        case unavailable(String)
        public var canRemove: Bool {
            self == .ready
        }
    }

    @Published public private(set) var state: State = .notAsked
    private var session: TemporaryAdminSession?
    private var starting: Task<TemporaryAdminSession, Error>?
    private var batchUsers = 0
    private var recoverySnapshot: [PrivilegedRecoveryItem]?
    private static var clients: [WeakClient] = []
    private struct WeakClient { weak var value: PrivilegedHelperClient? }

    public init() {
        Self.clients.append(WeakClient(value: self))
    }

    private var executable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BrimJobHelper")
    }

    public func refresh() {
        state = FileManager.default.isExecutableFile(atPath: executable.path)
            ? .ready : .unavailable("This copy of Brim does not include administrator cleanup.")
    }

    /// Called after a removal was approved, or an explicit recovery read.
    public func beginBatch() async -> String? {
        if session != nil {
            batchUsers += 1; return nil
        }
        refresh()
        guard state == .ready else { return "Administrator cleanup is unavailable in this copy of Brim." }
        if starting == nil {
            let executable = executable
            starting = Task { try await TemporaryAdminSession.start(executable: executable) }
        }
        guard let pending = starting else { return "Administrator cleanup could not start." }
        batchUsers += 1
        do {
            session = try await pending.value
            starting = nil
            return nil
        } catch {
            batchUsers -= 1
            starting = nil
            return error.localizedDescription
        }
    }

    public func endBatch() async {
        guard batchUsers > 0 else { return }
        batchUsers -= 1
        guard batchUsers == 0 else { return }
        let previous = session
        session = nil
        await previous?.finish()
    }

    /// Closing the app closes the channel, including during a command.
    public static func stopAll() {
        for client in clients.compactMap(\.value) {
            client.starting?.cancel()
            client.session?.stop()
            client.session = nil
        }
        clients.removeAll { $0.value == nil }
    }

    public func authorizeRecoveryRead() async -> String? {
        if let problem = await beginBatch() {
            return problem
        }
        do {
            recoverySnapshot = try await readRecoveryItems()
            await endBatch()
            return nil
        } catch {
            await endBatch()
            return error.localizedDescription
        }
    }

    public func listRecoveryItems() async throws -> [PrivilegedRecoveryItem] {
        // Scans use the explicit read snapshot. Applying a plan opens a new
        // session first and revalidates against a fresh administrator read.
        if session != nil {
            return try await readRecoveryItems()
        }
        guard let recoverySnapshot else {
            throw TemporaryAdminChannel.Failure("Read the recovery copies to select them for cleanup.")
        }
        return recoverySnapshot
    }

    public func freshRecoveryItems() async throws -> [PrivilegedRecoveryItem] {
        guard session != nil else {
            throw TemporaryAdminChannel.Failure("A fresh recovery check needs administrator authorization.")
        }
        return try await readRecoveryItems()
    }

    private func readRecoveryItems() async throws -> [PrivilegedRecoveryItem] {
        let response = try await request(.recoveryItems)
        if let complaint = response.complaint {
            throw TemporaryAdminChannel.Failure(complaint)
        }
        guard let data = response.data else { throw TemporaryAdminChannel.Failure("No recovery list was returned.") }
        let items = try JSONDecoder().decode([PrivilegedRecoveryItem].self, from: data)
        recoverySnapshot = items
        return items
    }

    private func request(_ command: TemporaryAdminRequest) async throws -> TemporaryAdminResponse {
        guard let session else { throw TemporaryAdminChannel.Failure("Administrator cleanup has not been authorized.") }
        return try await session.request(command)
    }

    private func remove(_ command: TemporaryAdminRequest) async -> String? {
        do { return try await request(command).complaint } catch { return error.localizedDescription }
    }

    public func removeDefunctJob(domain: PrivilegedJobRemoval.Domain, name: String) async -> String? {
        await remove(.removeDefunctJob(domain: domain.rawValue, name: name))
    }

    public func removeBrokenCommand(domain: PrivilegedLinkRemoval.Domain, name: String) async -> String? {
        await remove(.removeBrokenCommand(domain: domain.rawValue, name: name))
    }

    public func removeInstalledBundle(domain: PrivilegedBundleRemoval.Domain, name: String) async -> String? {
        await remove(.removeInstalledBundle(domain: domain.rawValue, name: name))
    }

    public func removeInstalledPayload(packageID: String, name: String) async -> String? {
        await remove(.removeInstalledPayload(packageID: packageID, name: name))
    }

    public func removeSystemCache(name: String) async -> String? {
        await remove(.removeSystemCache(name: name))
    }

    public func removeSystemPreference(name: String) async -> String? {
        await remove(.removeSystemPreference(name: name))
    }

    public func forgetReceipt(packageID: String) async -> String? {
        await remove(.forgetReceipt(packageID: packageID))
    }

    public func removeRecoveryItem(identifier: String, expectedDevice: Int32, expectedInode: UInt64) async -> String? {
        let problem = await remove(.removeRecoveryItem(identifier: identifier,
                                                       expectedDevice: expectedDevice, expectedInode: expectedInode))
        if problem == nil {
            recoverySnapshot = try? await readRecoveryItems()
        }
        return problem
    }

    /// Clears what only root can: Brim's folder in `/Library` and its grants
    /// in the system's privacy database. Asks for an administrator only when
    /// one of those is there.
    public func uninstall(resettingPrivacy: Bool = false) async -> String? {
        let folder = URL(fileURLWithPath: BrimJobHelper.quarantineDirectory).deletingLastPathComponent()
        if resettingPrivacy || FileManager.default.fileExists(atPath: folder.path) {
            if let problem = await beginBatch() {
                return problem
            }
            let problem = await remove(.uninstallSelf)
            await endBatch()
            if let problem {
                return problem
            }
        }
        return nil
    }
}
