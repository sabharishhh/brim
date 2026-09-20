import XCTest
@testable import BrimCore
@testable import BrimProtocol
@testable import BrimService

/// Covers the sequence the Review & Execute modal performs when the user
/// presses "Authorize & Remove": for each selected leftover, plan against a
/// `specificTarget` with the identity the UI can actually build from a
/// `Leftover` (often no bundle ID at all), then approve and apply each plan in
/// turn. The existing XPC integration test plans from a resolved app identity,
/// which is a different shape than anything the queue produces.
final class ReviewModalFlowIntegrationTests: XCTestCase {

    private func makeService(root rootURL: URL, support: URL) -> BrimService {
        BrimService(
            root: FileSystemRoot(rootURL: rootURL),
            brimAppURL: rootURL.appendingPathComponent("Applications/Brim.app"),
            planStoreDirectory: support.appendingPathComponent("Plans"),
            journalStoreDirectory: support.appendingPathComponent("Journals")
        )
    }

    /// Exactly what ReviewModal builds for one selected finding.
    private func modalIntent(title: String, target: URL) -> PlanIntent {
        PlanIntent(
            type: .uninstall,
            subjectIdentity: Identity(bundleID: nil, name: title),
            requesterKind: "ui",
            requesterIdentity: "test-user",
            specificTarget: target
        )
    }

    private func makeLeftover(at url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url.appendingPathComponent("payload.bin"))
    }

    func testAuthorizeAndRemoveTrashesEverySelectedTarget() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let caches = rootURL.appendingPathComponent("Users/\(NSUserName())/Library/Caches")
        let first = caches.appendingPathComponent("throwaway-one")
        let second = caches.appendingPathComponent("throwaway-two")
        try makeLeftover(at: first, bytes: 2048)
        try makeLeftover(at: second, bytes: 1024)

        let service = makeService(root: rootURL, support: tempDir)

        // --- generatePlans() ---
        var plans: [Plan] = []
        for (title, target) in [("throwaway-one", first), ("throwaway-two", second)] {
            let plan = try await service.plan(intent: modalIntent(title: title, target: target))
            XCTAssertFalse(plan.steps.isEmpty, "\(title) planned no steps; nothing would be removed")
            plans.append(plan)
        }

        XCTAssertEqual(Set(plans.flatMap { $0.steps.map(\.target) }), [first.path, second.path])

        // --- executePlans() ---
        for plan in plans {
            let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: "test-user")
            try await service.apply(planId: plan.planId, token: token)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))

        for plan in plans {
            let verification = try await service.verify(planId: plan.planId)
            XCTAssertTrue(verification.success, "verify() still sees targets: \(verification.reason ?? "")")
        }
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

        let plan = try await service.plan(intent: modalIntent(title: "throwaway-recoverable", target: target))
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

        let doomedPlan = try await service.plan(intent: modalIntent(title: "throwaway-doomed", target: doomed))
        let goodPlan = try await service.plan(intent: modalIntent(title: "throwaway-good", target: good))

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
