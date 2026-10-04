import BrimCore
@testable import BrimService
import Foundation
import Testing

struct ApplicationInventorySharingTests {
    /// Home opened Apps and Updates together, and each enumerated and sized
    /// every installed bundle. Keep the shared read gated until both join it.
    @Test func simultaneousReadsShareRecoveryAndEnumerationButLaterReadsAreFresh() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = service(in: directory)
        let reader = InventoryReads(applications: [application("1")], gated: true)
        await service.useApplicationInventory(reader: { await reader.read() }, recovery: { await reader.recover() })

        let first = await service.applicationInventoryRead()
        await waitUntil { await reader.readCount == 1 }
        let second = await service.applicationInventoryRead()
        #expect(await reader.readCount == 1)
        #expect(await reader.recoveryCount == 1)
        await reader.release()
        #expect(await first.value.map(\.version) == ["1"])
        #expect(await second.value.map(\.version) == ["1"])
        #expect(await reader.events == ["recover", "read"])

        await reader.replaceApplications([application("2")])
        let later = await service.applicationInventoryRead()
        #expect(await later.value.map(\.version) == ["2"])
        #expect(await reader.readCount == 2)
        #expect(await reader.recoveryCount == 2)
        #expect(await reader.events == ["recover", "read", "recover", "read"])
    }

    @Test func aCancelledAppsWaiterDoesNotCancelTheSharedReadOrWriteASnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = service(in: directory)
        let reader = InventoryReads(applications: [application("1")], gated: true)
        await service.useApplicationInventory(reader: { await reader.read() }, recovery: { await reader.recover() })
        let cancelled = Task { try await service.installedApplications() }
        await waitUntil { await reader.readCount == 1 }
        let surviving = await service.applicationInventoryRead()
        cancelled.cancel()
        await reader.release()

        do {
            _ = try await cancelled.value
            Issue.record("A cancelled inventory waiter wrote a snapshot.")
        } catch is CancellationError {
            // Only this waiter is cancelled, so the shared result is still usable.
        }
        #expect(await surviving.value.map(\.version) == ["1"])
        #expect(await reader.cancelledReads == 0)
        #expect(await service.whatChanged().snapshots == 0)
        _ = try await service.installedApplications()
        #expect(await reader.readCount == 2)
        #expect(await service.whatChanged().snapshots == 1)
    }

    @Test func appsKeepInterruptedRecoveryResultsForUpdatesAndUpdatesDoNotWriteSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = service(in: directory)
        let app = application("1")
        let reader = InventoryReads(applications: [app], interrupted: [app.url.path: "Interrupted"])
        await service.useApplicationInventory(reader: { await reader.read() }, recovery: { await reader.recover() })

        _ = try await service.installedApplications()
        #expect(await service.whatChanged().snapshots == 1)
        let check = await service.checkForUpdates()
        #expect(check.interrupted == [app.url.path: "Interrupted"])
        #expect(await service.whatChanged().snapshots == 1)
        #expect(await service.checkForUpdates().interrupted.isEmpty)
        #expect(await reader.readCount == 3)
    }

    private func service(in directory: URL) -> BrimService {
        BrimService(root: FileSystemRoot(rootURL: directory.appendingPathComponent("Root")),
                    brimAppURL: directory.appendingPathComponent("Brim.app"),
                    planStoreDirectory: directory.appendingPathComponent("Plans"),
                    journalStoreDirectory: directory.appendingPathComponent("Journals"))
    }

    private func application(_ version: String) -> InstalledApplication {
        // A protected fixture has no update source, so these service tests
        // never need a network request or a real installed application.
        InstalledApplication(identity: Identity(bundleID: "org.example.inventory", name: "Fixture", version: version),
                             url: URL(fileURLWithPath: "/fixture/Fixture.app"),
                             bundleSizeBytes: 100, isSystemProtected: true)
    }

    private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while await !predicate(), ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await predicate())
    }
}

private actor InventoryReads {
    private var applications: [InstalledApplication]
    private var interrupted: [String: String]
    private var gated: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var readCount = 0
    private(set) var recoveryCount = 0
    private(set) var cancelledReads = 0
    private(set) var events: [String] = []

    init(applications: [InstalledApplication], gated: Bool = false, interrupted: [String: String] = [:]) {
        self.applications = applications
        self.gated = gated
        self.interrupted = interrupted
    }

    func recover() -> [String: String] {
        recoveryCount += 1
        events.append("recover")
        defer { interrupted = [:] }
        return interrupted
    }

    func read() async -> [InstalledApplication] {
        readCount += 1
        events.append("read")
        if gated {
            await withCheckedContinuation { continuation = $0 }
        }
        if Task.isCancelled {
            cancelledReads += 1
        }
        return applications
    }

    func release() {
        gated = false
        continuation?.resume()
        continuation = nil
    }

    func replaceApplications(_ applications: [InstalledApplication]) {
        self.applications = applications
    }
}
