import XCTest
import BrimCore
import BrimProtocol
@testable import BrimUI

/// A list catches up the moment something becomes true, not when a sheet is
/// dismissed.
///
/// The incident: removing one leftover, watching the check go green, and
/// then watching the row sit there. Pressing Done triggered a full rescan of
/// the Mac, four hundred milliseconds, and only then did the row go. The
/// answer had been available since verification: `verify` re-observes every
/// path with `lstat` and knows exactly which ones survived. It computed
/// that, reported a yes or no, and threw the detail away.
@MainActor
final class InstantFeedbackTests: XCTestCase {

    private func leftover(
        _ path: String, _ category: Leftover.Category = .orphaned
    ) -> Leftover {
        Leftover(
            url: URL(fileURLWithPath: path), size: 10, category: category,
            potentialOwner: Identity(bundleID: nil, name: (path as NSString).lastPathComponent),
            evidence: "because"
        )
    }

    private func loaded(_ items: [Leftover]) async -> LeftoversModel {
        let model = LeftoversModel()
        await model.load(service: LeftoverStub(items))
        return model
    }

    func testAProvedRemovalDropsTheRowWithoutRescanning() async {
        let model = await loaded([leftover("/tmp/a"), leftover("/tmp/b")])
        XCTAssertEqual(model.orphanedGroups.count, 2)

        model.forget(paths: ["/tmp/a"])

        XCTAssertEqual(model.orphanedGroups.map(\.displayName), ["b"])
        XCTAssertFalse(model.selection.contains(URL(fileURLWithPath: "/tmp/a").path),
                       "A row that has gone cannot stay ticked")
    }

    /// The other half, and the one worth protecting. Something that survived
    /// the removal is still on the disk, so it stays on screen: a broken
    /// command in a root-owned folder is exactly this case.
    func testWhatSurvivedStaysOnScreen() async {
        let model = await loaded([leftover("/tmp/gone"), leftover("/tmp/stayed")])
        model.forget(paths: ["/tmp/gone"])
        XCTAssertEqual(model.orphanedGroups.map(\.displayName), ["stayed"])
    }

    func testTheOpenDetailClosesWhenItsSubjectGoes() async {
        let model = await loaded([leftover("/tmp/a"), leftover("/tmp/b")])
        model.inspected = model.orphanedGroups.first { $0.displayName == "a" }
        XCTAssertNotNil(model.inspected)

        model.forget(paths: ["/tmp/a"])
        XCTAssertNil(model.inspected, "A detail pane about something removed is about nothing")
    }

    /// Two locations belonging to one application, which is the ordinary
    /// case: `Application Support/Thing` and `Caches/Thing`.
    func testTheDetailStaysOpenAndUpdatesWhenOnlyPartOfItGoes() async {
        let model = await loaded([
            leftover("/tmp/Application Support/Thing"),
            leftover("/tmp/Caches/Thing"),
        ])
        XCTAssertEqual(model.orphanedGroups.count, 1, "One application, two locations")
        model.inspected = model.orphanedGroups.first
        let subject = model.inspected?.id

        model.forget(paths: ["/tmp/Caches/Thing"])

        XCTAssertEqual(model.inspected?.id, subject,
                       "One of two locations going is not a reason to close the pane")
        XCTAssertEqual(model.inspected?.items.count, 1,
                       "And the pane must not go on listing the location that has gone")
    }

    // MARK: - Putting it back

    /// Everything here went to the Trash, and the Trash is a place people
    /// take things out of again. A restored file is back at the path it came
    /// from, and the row belongs back in the list.
    func testRestoringFromTheTrashBringsTheRowBack() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Restored")
        try Data("x".utf8).write(to: file)

        let model = await loaded([leftover(file.path), leftover("/tmp/other")])
        model.forget(paths: [file.path])
        XCTAssertEqual(model.orphanedGroups.count, 1)

        // The file is still there, as it would be after a restore.
        model.reconcileWithDisk()
        XCTAssertEqual(model.orphanedGroups.count, 2, "It is back on disk, so it is back in the list")
    }

    func testSomethingStillGoneDoesNotComeBack() async {
        let model = await loaded([leftover("/tmp/definitely-not-here-\(UUID().uuidString)")])
        let path = model.orphanedGroups[0].items[0].url.path
        model.forget(paths: [path])
        XCTAssertTrue(model.orphanedGroups.isEmpty)

        model.reconcileWithDisk()
        XCTAssertTrue(model.orphanedGroups.isEmpty, "Nothing is at that path, so nothing returns")
    }

    func testAFreshScanForgetsWhatItWasHoldingForARestore() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Thing")
        try Data("x".utf8).write(to: file)

        let model = await loaded([leftover(file.path)])
        model.forget(paths: [file.path])
        // A new scan is the truth and already looked at the disk itself.
        await model.load(service: LeftoverStub([]))
        model.reconcileWithDisk()
        XCTAssertTrue(model.orphanedGroups.isEmpty,
                      "The scan said nothing is there; a stale restore list must not argue")
    }

    // MARK: - What verification hands over

    func testVerificationNamesWhatWentRatherThanJustWhetherItWorked() {
        let result = VerificationResult(
            planId: UUID(), expectedBytes: 0, recoveredBytes: 0,
            success: false, reason: "because", remainingPaths: ["/tmp/stayed"]
        )
        XCTAssertEqual(
            result.removedPaths(from: ["/tmp/gone", "/tmp/stayed"]), ["/tmp/gone"]
        )
    }
}

private actor LeftoverStub: BrimServiceProtocol {
    let items: [Leftover]
    init(_ items: [Leftover]) { self.items = items }
    func leftovers() async throws -> [Leftover] { items }

    func inspect(identity: Identity) async throws -> Footprint { throw No.no }
    func plan(intent: PlanIntent) async throws -> Plan { throw No.no }
    func explain(planId: UUID) async throws -> String { throw No.no }
    func requestApproval(planId: UUID, requesterIdentity: String) async throws
        -> ApprovalRequestReceipt { throw No.no }
    func apply(planId: UUID, token: ApprovalToken) async throws { throw No.no }
    func verify(planId: UUID) async throws -> VerificationResult { throw No.no }
    func history() async throws -> [Plan] { [] }
    func undo(planId: UUID) async throws { throw No.no }
    func dumpBTM() async throws -> String { "" }
    func installedApplications() async throws -> [InstalledApplication] { [] }
    func recoverableItems() async throws -> [RecoverableItem] { [] }
    func scanDuplicates(in directory: URL) async throws -> [DuplicateGroup] { [] }
}

private enum No: Error { case no }
