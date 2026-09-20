import XCTest
@testable import BrimCore
@testable import BrimProtocol
@testable import BrimService

/// Covers the sequence the Review & Execute modal performs when the user
/// presses "Authorize & Remove": plan the whole selection as ONE plan against
/// `specificTargets`, with the identity the UI can build from a `Leftover`
/// (often no bundle ID at all), then take a single approval and apply it. The
/// existing XPC integration test plans from a resolved app identity, which is
/// a different shape than anything the queue produces.
final class ReviewModalFlowIntegrationTests: XCTestCase {

    private func makeService(root rootURL: URL, support: URL) -> BrimService {
        BrimService(
            root: FileSystemRoot(rootURL: rootURL),
            brimAppURL: rootURL.appendingPathComponent("Applications/Brim.app"),
            planStoreDirectory: support.appendingPathComponent("Plans"),
            journalStoreDirectory: support.appendingPathComponent("Journals")
        )
    }

    /// Exactly what ReviewModal builds for a selection.
    private func modalIntent(title: String, targets: [URL]) -> PlanIntent {
        PlanIntent(
            type: .uninstall,
            subjectIdentity: Identity(bundleID: nil, name: title),
            requesterKind: "ui",
            requesterIdentity: "test-user",
            specificTargets: targets
        )
    }

    /// requestApproval skips the LAContext prompt only when it can tell it is
    /// running under a test harness. If this detection breaks, the whole suite
    /// starts demanding a fingerprint per plan on any Mac with working Touch
    /// ID — which is what happened while it keyed off
    /// XCTestConfigurationFilePath, a variable SwiftPM's runner never sets.
    func testSuiteIsRecognisableAsAnAutomatedRun() {
        XCTAssertTrue(
            BrimService.isAutomatedRun,
            "Tests would block on human authentication without this"
        )
        XCTAssertNil(
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"],
            "swift test does not set this, so detection must not depend on it"
        )
    }

    private func makeLeftover(at url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url.appendingPathComponent("payload.bin"))
    }

    func testOneApprovalRemovesEverySelectedTarget() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let caches = rootURL.appendingPathComponent("Users/\(NSUserName())/Library/Caches")
        let first = caches.appendingPathComponent("throwaway-one")
        let second = caches.appendingPathComponent("throwaway-two")
        try makeLeftover(at: first, bytes: 2048)
        try makeLeftover(at: second, bytes: 1024)

        let service = makeService(root: rootURL, support: tempDir)

        // --- generatePlans(): the whole selection becomes one plan ---
        let plan = try await service.plan(intent: modalIntent(title: "2 selected items", targets: [first, second]))
        XCTAssertEqual(Set(plan.steps.map(\.target)), [first.path, second.path],
                       "One plan must cover every selected target")

        // --- executePlans(): exactly one approval for the batch ---
        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: "test-user")
        try await service.apply(planId: plan.planId, token: token)

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))

        let verification = try await service.verify(planId: plan.planId)
        XCTAssertTrue(verification.success, "verify() still sees targets: \(verification.reason ?? "")")
    }

    func testBatchTokenIsBoundToTheWholeSelection() async throws {
        // The single token covers every step, so its plan hash changes if the
        // selection does — approving two items cannot authorize a third.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let caches = rootURL.appendingPathComponent("Users/\(NSUserName())/Library/Caches")
        let a = caches.appendingPathComponent("batch-a")
        let b = caches.appendingPathComponent("batch-b")
        let c = caches.appendingPathComponent("batch-c")
        for url in [a, b, c] { try makeLeftover(at: url, bytes: 128) }

        let service = makeService(root: rootURL, support: tempDir)

        let twoItems = try await service.plan(intent: modalIntent(title: "2 selected items", targets: [a, b]))
        let threeItems = try await service.plan(intent: modalIntent(title: "3 selected items", targets: [a, b, c]))

        XCTAssertEqual(twoItems.steps.count, 2)
        XCTAssertEqual(threeItems.steps.count, 3)
        XCTAssertNotEqual(try twoItems.contentHash(), try threeItems.contentHash())

        let token = try await service.requestApproval(planId: twoItems.planId, requesterIdentity: "test-user")
        try await service.apply(planId: twoItems.planId, token: token)

        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.path),
                      "An item outside the approved plan must survive")
    }

    func testASingleSelectionStillPlansAsBefore() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let only = rootURL
            .appendingPathComponent("Users/\(NSUserName())/Library/Caches")
            .appendingPathComponent("throwaway-single")
        try makeLeftover(at: only, bytes: 64)

        let service = makeService(root: rootURL, support: tempDir)
        let plan = try await service.plan(intent: modalIntent(title: "throwaway-single", targets: [only]))

        XCTAssertEqual(plan.steps.map(\.target), [only.path])
    }

    func testLegacySingleTargetIntentsStillPlan() async throws {
        // Plans and callers written before batching pass specificTarget.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let target = rootURL
            .appendingPathComponent("Users/\(NSUserName())/Library/Caches")
            .appendingPathComponent("legacy-target")
        try makeLeftover(at: target, bytes: 64)

        let service = makeService(root: rootURL, support: tempDir)
        let legacy = PlanIntent(
            type: .uninstall,
            subjectIdentity: Identity(bundleID: nil, name: "legacy-target"),
            requesterKind: "ui",
            requesterIdentity: "test-user",
            specificTarget: target
        )

        let plan = try await service.plan(intent: legacy)
        XCTAssertEqual(plan.steps.map(\.target), [target.path])
    }

    func testRemovedTargetIsRecoverableFromTheTrash() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let target = rootURL
            .appendingPathComponent("Users/\(NSUserName())/Library/Caches")
            .appendingPathComponent("throwaway-recoverable")
        try makeLeftover(at: target, bytes: 512)

        let service = makeService(root: rootURL, support: tempDir)

        let plan = try await service.plan(intent: modalIntent(title: "throwaway-recoverable", targets: [target]))
        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: "test-user")
        try await service.apply(planId: plan.planId, token: token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        // "Authorize & Remove" trashes rather than unlinks, so undo can put it back.
        try await service.undo(planId: plan.planId)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: target.appendingPathComponent("payload.bin").path),
            "Undo did not restore the trashed target"
        )
    }

    func testOnePlanFailingDoesNotStopTheOthersFromBeingRemoved() async throws {
        // ReviewModal keeps whatever already succeeded when a later plan fails,
        // so a plan whose target vanished must not strand the rest.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let caches = rootURL.appendingPathComponent("Users/\(NSUserName())/Library/Caches")
        let good = caches.appendingPathComponent("throwaway-good")
        let doomed = caches.appendingPathComponent("throwaway-doomed")
        try makeLeftover(at: good, bytes: 256)
        try makeLeftover(at: doomed, bytes: 256)

        let service = makeService(root: rootURL, support: tempDir)

        let doomedPlan = try await service.plan(intent: modalIntent(title: "throwaway-doomed", targets: [doomed]))
        let goodPlan = try await service.plan(intent: modalIntent(title: "throwaway-good", targets: [good]))

        // The target disappears between planning and applying.
        try FileManager.default.removeItem(at: doomed)

        let doomedToken = try await service.requestApproval(planId: doomedPlan.planId, requesterIdentity: "test-user")
        do {
            try await service.apply(planId: doomedPlan.planId, token: doomedToken)
        } catch {
            // Expected: revalidation refuses a plan whose footprint changed.
        }

        let goodToken = try await service.requestApproval(planId: goodPlan.planId, requesterIdentity: "test-user")
        try await service.apply(planId: goodPlan.planId, token: goodToken)

        XCTAssertFalse(FileManager.default.fileExists(atPath: good.path), "The healthy target should still be removed")
    }
}
