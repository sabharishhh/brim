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

    /// The plan records actually on disk, by file name.
    private func storedPlanFiles(in support: URL) -> [String] {
        let plansDir = support.appendingPathComponent("Plans")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: plansDir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }

    func testApplyDoesNotPersistItsRevalidationPlan() async throws {
        // apply() re-plans to check the footprint has not mutated. That
        // throwaway plan used to go through the saving path, leaving a second
        // record with identical steps and no ledger entry.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let target = rootURL
            .appendingPathComponent("Users/\(NSUserName())/Library/Caches")
            .appendingPathComponent("throwaway-one-record")
        try makeLeftover(at: target, bytes: 256)

        let service = makeService(root: rootURL, support: tempDir)

        let plan = try await service.plan(intent: modalIntent(title: "throwaway-one-record", targets: [target]))
        XCTAssertEqual(storedPlanFiles(in: tempDir), ["\(plan.planId.uuidString).json"])

        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: "test-user")
        try await service.apply(planId: plan.planId, token: token)

        XCTAssertEqual(
            storedPlanFiles(in: tempDir),
            ["\(plan.planId.uuidString).json"],
            "apply() must leave only the plan it applied"
        )
    }

    func testApplyingABatchLeavesOneRecordNotOnePerTarget() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let caches = rootURL.appendingPathComponent("Users/\(NSUserName())/Library/Caches")
        let targets = ["one", "two", "three"].map { caches.appendingPathComponent("batch-record-\($0)") }
        for url in targets { try makeLeftover(at: url, bytes: 128) }

        let service = makeService(root: rootURL, support: tempDir)

        let plan = try await service.plan(intent: modalIntent(title: "3 selected items", targets: targets))
        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: "test-user")
        try await service.apply(planId: plan.planId, token: token)

        XCTAssertEqual(
            storedPlanFiles(in: tempDir),
            ["\(plan.planId.uuidString).json"],
            "Three targets removed together should leave one plan record"
        )
    }

    func testRecoverableItemsTracksTheTrashRatherThanTheJournal() async throws {
        // What the UI shows must follow the Trash as it is now, so emptying it
        // in Finder changes the answer without the app restarting.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settings = rootURL
            .appendingPathComponent("Users/\(NSUserName())/Library/Application Support")
            .appendingPathComponent("recoverable-settings")
        let cache = rootURL
            .appendingPathComponent("Users/\(NSUserName())/Library/Caches")
            .appendingPathComponent("gone-forever-cache")
        try makeLeftover(at: settings, bytes: 512)
        try makeLeftover(at: cache, bytes: 512)

        let service = makeService(root: rootURL, support: tempDir)

        for (title, target) in [("recoverable-settings", settings), ("gone-forever-cache", cache)] {
            let plan = try await service.plan(intent: modalIntent(title: title, targets: [target]))
            let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: "test-user")
            try await service.apply(planId: plan.planId, token: token)
        }

        // The permanently deleted cache is never recoverable; the trashed
        // settings data is.
        let afterApply = try await service.recoverableItems()
        XCTAssertEqual(afterApply.map(\.name), ["recoverable-settings"])
        XCTAssertGreaterThan(afterApply.first?.bytes ?? 0, 0)

        // Stand in for the user emptying the Trash in Finder.
        let journalStore = JournalStore(directoryURL: tempDir.appendingPathComponent("Journals"))
        let recoverablePlanId = try XCTUnwrap(afterApply.first?.planId)
        let journal = try await journalStore.load(planId: recoverablePlanId)
        for url in (journal?.stepTrashedURLs ?? [:]).values {
            try FileManager.default.removeItem(at: url)
        }

        let afterEmptying = try await service.recoverableItems()
        XCTAssertTrue(
            afterEmptying.isEmpty,
            "Emptying the Trash must be reflected immediately, not cached from the journal"
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

    func testSettingsDataIsTrashedAndRecoverable() async throws {
        // Application Support is medium cost: it holds settings and profile
        // data, which is the case where undo actually matters.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let target = rootURL
            .appendingPathComponent("Users/\(NSUserName())/Library/Application Support")
            .appendingPathComponent("throwaway-recoverable")
        try makeLeftover(at: target, bytes: 512)

        let service = makeService(root: rootURL, support: tempDir)

        let plan = try await service.plan(intent: modalIntent(title: "throwaway-recoverable", targets: [target]))
        XCTAssertEqual(plan.steps.map(\.effectiveDisposition), [.trash])
        XCTAssertTrue(plan.isReversible)
        XCTAssertEqual(plan.immediatelyFreedBytes, 0, "Trashing frees nothing until the Trash is emptied")
        XCTAssertGreaterThan(plan.trashedBytes, 0)

        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: "test-user")
        try await service.apply(planId: plan.planId, token: token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        try await service.undo(planId: plan.planId)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: target.appendingPathComponent("payload.bin").path),
            "Undo did not restore the trashed target"
        )
    }

    func testCacheIsDeletedOutrightAndReportsFreedSpace() async throws {
        // Nobody restores a rebuilt cache, and trashing it would mean the
        // space the sheet promised never actually comes back.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let target = rootURL
            .appendingPathComponent("Users/\(NSUserName())/Library/Caches")
            .appendingPathComponent("throwaway-cache")
        try makeLeftover(at: target, bytes: 4096)

        let service = makeService(root: rootURL, support: tempDir)

        let plan = try await service.plan(intent: modalIntent(title: "throwaway-cache", targets: [target]))
        XCTAssertEqual(plan.steps.map(\.effectiveDisposition), [.delete])
        XCTAssertFalse(plan.isReversible)
        XCTAssertGreaterThan(plan.immediatelyFreedBytes, 0)
        XCTAssertEqual(plan.trashedBytes, 0)

        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: "test-user")
        try await service.apply(planId: plan.planId, token: token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        // Nothing was trashed, so the journal records no restore path...
        let journal = try await JournalStore(directoryURL: tempDir.appendingPathComponent("Journals")).load(planId: plan.planId)
        XCTAssertTrue((journal?.stepTrashedURLs ?? [:]).isEmpty)

        // ...and undo says so plainly instead of failing on a missing file.
        do {
            try await service.undo(planId: plan.planId)
            XCTFail("Undo should refuse a permanent removal")
        } catch let error as BrimService.UndoError {
            guard case .planWasPermanent = error else {
                return XCTFail("Wrong case: \(error)")
            }
            XCTAssertEqual(error.errorDescription, "This removal was permanent, so there is nothing to restore.")
        }
    }

    func testUndoRefusesCleanlyOnceTheTrashHasBeenEmptied() async throws {
        // The ordinary case: the user empties the Trash, then tries to undo.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let target = rootURL
            .appendingPathComponent("Users/\(NSUserName())/Library/Application Support")
            .appendingPathComponent("throwaway-emptied")
        try makeLeftover(at: target, bytes: 256)

        let service = makeService(root: rootURL, support: tempDir)
        let plan = try await service.plan(intent: modalIntent(title: "throwaway-emptied", targets: [target]))
        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: "test-user")
        try await service.apply(planId: plan.planId, token: token)

        // Stand in for the user emptying the Trash.
        let journalStore = JournalStore(directoryURL: tempDir.appendingPathComponent("Journals"))
        let journal = try await journalStore.load(planId: plan.planId)
        let trashed = try XCTUnwrap(journal?.stepTrashedURLs?.values.first)
        try FileManager.default.removeItem(at: trashed)

        do {
            try await service.undo(planId: plan.planId)
            XCTFail("Undo should refuse when the Trash no longer holds the item")
        } catch let error as BrimService.UndoError {
            guard case .noLongerInTrash(let targets) = error else {
                return XCTFail("Wrong case: \(error)")
            }
            XCTAssertEqual(targets, [target.path])
            XCTAssertEqual(
                error.errorDescription,
                "No longer in the Trash, so it cannot be restored: throwaway-emptied."
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.path),
            "A refused undo must not half-restore anything"
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
