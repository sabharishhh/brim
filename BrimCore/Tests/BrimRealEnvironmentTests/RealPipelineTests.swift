import XCTest
import BrimCore
import BrimProtocol
@testable import BrimService

/// Drives the real pipeline against the real machine: real domains, the real
/// scanner, the real Trash.
///
/// Opt-in via `BRIM_REAL_ENV=1`. Everything it creates is namespaced and
/// removed in teardown, and it never plans against a target it did not make.
final class RealPipelineTests: XCTestCase {

    private var fixture = RealEnvironmentFixture()
    private var supportDirectory: URL!

    override func setUpWithError() throws {
        try RealEnvironmentFixture.requireEnabled(self)
        fixture = RealEnvironmentFixture()
        supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrimHarnessStore-\(UUID().uuidString)")
    }

    override func tearDown() {
        fixture.cleanUp()
        if let supportDirectory {
            try? FileManager.default.removeItem(at: supportDirectory)
        }
        super.tearDown()
    }

    /// The real service: root `/`, real scanning, stores kept in a temp
    /// directory so a harness run never touches the user's own ledger.
    private func makeService() -> BrimService {
        BrimService(
            root: FileSystemRoot(rootURL: URL(fileURLWithPath: "/")),
            brimAppURL: Bundle.main.bundleURL,
            planStoreDirectory: supportDirectory.appendingPathComponent("Plans"),
            journalStoreDirectory: supportDirectory.appendingPathComponent("Journals")
        )
    }

    private func uninstallIntent(named name: String, targets: [URL]) -> PlanIntent {
        PlanIntent(
            type: .uninstall,
            subjectIdentity: Identity(bundleID: nil, name: name),
            requesterKind: "harness",
            requesterIdentity: NSUserName(),
            specificTargets: targets
        )
    }

    // MARK: - Scanning

    func testTheRealScannerFindsATargetPlacedInARealDomain() async throws {
        let target = try fixture.makeTarget(in: fixture.cachesDomain, name: "scan")
        let service = makeService()

        let leftovers = try await service.leftovers()
        let found = leftovers.first { $0.url.standardizedFileURL == target.standardizedFileURL }

        XCTAssertNotNil(
            found,
            "The real scanner did not see a directory sitting in ~/Library/Caches. "
            + "Without Full Disk Access this is expected — see docs/requirements.md."
        )
        XCTAssertEqual(found?.category, .unclaimed, "Nothing owns a harness directory")
    }

    // MARK: - Disposition, end to end on the real disk

    func testACacheIsPermanentlyDeletedAndTheSpaceIsReleased() async throws {
        let target = try fixture.makeTarget(in: fixture.cachesDomain, name: "cache")
        let service = makeService()

        let plan = try await service.plan(intent: uninstallIntent(named: "harness-cache", targets: [target]))
        XCTAssertEqual(plan.steps.map(\.effectiveDisposition), [.delete],
                       "Caches are low cost of error and should not linger in the Trash")
        XCTAssertFalse(plan.isReversible)

        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
        try await service.apply(planId: plan.planId, token: token)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        let journal = try await JournalStore(directoryURL: supportDirectory.appendingPathComponent("Journals"))
            .load(planId: plan.planId)
        XCTAssertTrue((journal?.stepTrashedURLs ?? [:]).isEmpty,
                      "A permanent delete must not leave a Trash copy behind")

        let verification = try await service.verify(planId: plan.planId)
        XCTAssertTrue(verification.success, verification.reason ?? "")
    }

    func testSettingsDataGoesToTheRealTrashAndCanBeRestored() async throws {
        let target = try fixture.makeTarget(in: fixture.applicationSupportDomain, name: "settings")
        let service = makeService()

        let plan = try await service.plan(intent: uninstallIntent(named: "harness-settings", targets: [target]))
        XCTAssertEqual(plan.steps.map(\.effectiveDisposition), [.trash])
        XCTAssertTrue(plan.isReversible)

        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
        try await service.apply(planId: plan.planId, token: token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        // It is genuinely in the user's Trash, not merely gone.
        let recoverable = try await service.recoverableItems()
        XCTAssertTrue(recoverable.contains { $0.planId == plan.planId },
                      "A trashed removal should be listed as recoverable")

        try await service.undo(planId: plan.planId)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: target.appendingPathComponent("README.txt").path),
            "Undo should restore the real directory, contents intact"
        )

        let afterUndo = try await service.recoverableItems()
        XCTAssertFalse(afterUndo.contains { $0.planId == plan.planId },
                       "A restored removal is no longer recoverable")
    }

    // MARK: - Batching, on real targets

    func testOneApprovalCoversAMixedSelectionOfRealTargets() async throws {
        let cache = try fixture.makeTarget(in: fixture.cachesDomain, name: "batch-cache")
        let settings = try fixture.makeTarget(in: fixture.applicationSupportDomain, name: "batch-settings")
        let service = makeService()

        let plan = try await service.plan(
            intent: uninstallIntent(named: "2 selected items", targets: [cache, settings])
        )

        XCTAssertEqual(plan.steps.count, 2, "One plan must cover the whole selection")
        XCTAssertGreaterThan(plan.immediatelyFreedBytes, 0, "The cache half frees space at once")
        XCTAssertGreaterThan(plan.trashedBytes, 0, "The settings half only frees on emptying the Trash")

        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
        try await service.apply(planId: plan.planId, token: token)

        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))

        // Put the recoverable half back so teardown is not relying on the Trash.
        try await service.undo(planId: plan.planId)
    }
}
