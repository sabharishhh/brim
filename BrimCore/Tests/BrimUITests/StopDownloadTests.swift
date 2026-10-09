import BrimCore
import BrimProtocol
import BrimUI
import Foundation
import Testing

/// Stopping a download puts the row back to offering the update; stopping
/// is refused once the update is installing.
@MainActor struct StopDownloadTests {
    private let update = AppUpdate(
        bundleID: "com.example.demo", name: "Demo", appURL: URL(fileURLWithPath: "/Applications/Demo.app"),
        installedVersion: "1.0", latestVersion: "1.1", origin: .sparkle(feed: "https://example.com/appcast.xml"),
        route: .replace,
        download: UpdateDownload(url: URL(string: "https://example.com/Demo.zip")!, bytes: 100, integrity: .none)
    )

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func `stopping a download offers the update again`() async {
        let model = UpdatesModel()
        let service = SlowDownload(installing: false)
        await model.load(service: service)
        let installing = Task { await model.install(update, service: service) }
        await waitFor {
            if case let .downloading(progress) = model.states[update.id] {
                return progress.received > 0
            }
            return false
        }
        model.cancelDownload(of: update)
        await installing.value
        #expect(model.states[update.id] == nil)
        #expect(model.count == 1)
    }

    @Test func `an update that is installing is not stopped`() async {
        let model = UpdatesModel()
        let service = SlowDownload(installing: true)
        await model.load(service: service)
        let installing = Task { await model.install(update, service: service) }
        await waitFor { model.states[update.id] == .installing }
        model.cancelDownload(of: update)
        await service.finish()
        await installing.value
        #expect(model.states[update.id] == .updated("1.1"))
    }
}

/// Downloads until cancelled, or reports installing and waits to be told
/// to finish.
private actor SlowDownload: BrimServiceProtocol {
    let installing: Bool
    private var release: CheckedContinuation<Void, Never>?

    init(installing: Bool) {
        self.installing = installing
    }

    func finish() {
        release?.resume()
        release = nil
    }

    func checkForUpdates() async -> UpdateCheck {
        UpdateCheck(updates: [AppUpdate(
            bundleID: "com.example.demo", name: "Demo", appURL: URL(fileURLWithPath: "/Applications/Demo.app"),
            installedVersion: "1.0", latestVersion: "1.1", origin: .sparkle(feed: "https://example.com/appcast.xml"),
            route: .replace,
            download: UpdateDownload(url: URL(string: "https://example.com/Demo.zip")!, bytes: 100, integrity: .none)
        )], checked: 1, unchecked: [], checkedAt: Date())
    }

    func installUpdate(
        _: AppUpdate, progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async -> UpdateOutcome {
        if installing {
            progress(DownloadProgress(received: 100, expected: 100))
            await withCheckedContinuation { release = $0 }
            return .installed(version: "1.1")
        }
        progress(DownloadProgress(received: 10, expected: 100))
        do {
            try await Task.sleep(for: .seconds(30))
            return .installed(version: "1.1")
        } catch {
            return .cancelled
        }
    }

    func leftovers() async throws -> [Leftover] {
        []
    }

    func installedApplications() async throws -> [InstalledApplication] {
        []
    }

    func recoverableItems() async throws -> [RecoverableItem] {
        []
    }

    func history() async throws -> [Plan] {
        []
    }

    func inspect(identity _: Identity) async throws -> Footprint {
        throw Unused.unused
    }

    func plan(intent _: PlanIntent) async throws -> Plan {
        throw Unused.unused
    }

    func requestApproval(planId _: UUID, requesterIdentity _: String) async throws -> ApprovalRequestReceipt {
        throw Unused.unused
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {
        throw Unused.unused
    }

    func verify(planId _: UUID) async throws -> VerificationResult {
        throw Unused.unused
    }

    func undo(planId _: UUID) async throws {
        throw Unused.unused
    }
}

private enum Unused: Error { case unused }
