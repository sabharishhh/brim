import BrimCore
import BrimProtocol
@testable import BrimUI
import Combine
import XCTest

private actor LeftoversStub: BrimServiceProtocol {
    let items: [Leftover]
    let failure: Error?
    var calls = 0
    init(_ items: [Leftover], failure: Error? = nil) {
        self.items = items
        self.failure = failure
    }

    func leftovers() async throws -> [Leftover] {
        calls += 1
        if let failure {
            throw failure
        }
        return items
    }

    func inspect(identity _: Identity) async throws -> Footprint {
        throw Nope.no
    }

    func plan(intent _: PlanIntent) async throws -> Plan {
        throw Nope.no
    }

    func requestApproval(planId _: UUID, requesterIdentity _: String) async throws -> ApprovalRequestReceipt {
        throw Nope.no
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {
        throw Nope.no
    }

    func verify(planId _: UUID) async throws -> VerificationResult {
        throw Nope.no
    }

    func history() async throws -> [Plan] {
        []
    }

    func undo(planId _: UUID) async throws {
        throw Nope.no
    }

    func installedApplications() async throws -> [InstalledApplication] {
        []
    }

    func recoverableItems() async throws -> [RecoverableItem] {
        []
    }
}

private enum Nope: Error { case no }

private func leftover(
    _ name: String,
    _ category: Leftover.Category,
    size: Int64 = 1024,
    capability: Capability = .ok
) -> Leftover {
    Leftover(
        url: URL(fileURLWithPath: "/tmp/leftovers/\(name)"),
        size: size,
        category: category,
        evidence: category == .orphaned ? "a record named an owner that has gone" : "nothing claims it",
        capability: capability
    )
}

@MainActor
final class LeftoversModelTests: XCTestCase {
    func testUnknownReviewCountMatchesTheDetailedList() async {
        let model = LeftoversModel()
        await model.load(service: LeftoversStub([
            leftover("small", .unclaimed, size: 100),
            leftover("large", .unclaimed, size: 1_000_000),
            leftover("protected", .unclaimed, size: 0, capability: .needsFullDiskAccess)
        ]))
        XCTAssertEqual(Set(model.unclaimedGroupsForReview.map(\.displayName)), ["large", "protected"])
    }

    func testEmptySuccessfulScanIsCachedAcrossNavigation() async {
        let service = LeftoversStub([])
        let model = LeftoversModel()
        await model.loadIfNeeded(service: service)
        await model.loadIfNeeded(service: service)
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
    }

    /// The grouped lists are stored now rather than recomputed on read, so
    /// they have to be reassigned everywhere the flat lists are. Grouping two
    /// hundred and fifty leftovers ran several times per body evaluation when
    /// it was a computed property, which is why it moved; the price of moving
    /// it is that a stale group list is now possible and was not before.
    func testTheGroupedListsNeverLagBehindTheFlatOnes() async {
        let model = LeftoversModel()
        await model.load(service: LeftoversStub([
            leftover("Codex", .orphaned), leftover("Codex", .orphaned),
            leftover("Loki", .unclaimed)
        ]))

        XCTAssertEqual(model.orphanedGroups, model.orphaned.groupedByOwner())
        XCTAssertEqual(model.unclaimedGroups, model.unclaimed.groupedByOwner())

        // And again after a second, different load.
        await model.load(service: LeftoversStub([leftover("Warp", .unclaimed)]))
        XCTAssertTrue(model.orphanedGroups.isEmpty, "The previous run's orphans are not this run's")
        XCTAssertEqual(model.unclaimedGroups, model.unclaimed.groupedByOwner())
    }

    func testAFailedScanClearsTheLastRunRatherThanLeavingItOnScreen() async {
        let model = LeftoversModel()
        await model.load(service: LeftoversStub([leftover("Codex", .orphaned)]))
        XCTAssertFalse(model.orphanedGroups.isEmpty)

        await model.load(service: LeftoversStub([], failure: Nope.no))

        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.checkedAt, "A failed check is not an empty successful scan")
        XCTAssertTrue(model.orphanedGroups.isEmpty, "A failed sweep shows no rows, not old rows")
        XCTAssertTrue(model.all.isEmpty)
        XCTAssertTrue(model.selection.isEmpty, "Nothing stays ticked from a run that did not happen")
    }

    func testOnlyOrphansArePreSelected() async {
        // The whole point of the two-category model. An unclaimed item is
        // one the search could not attribute: pre-selecting it would turn
        // an absence of evidence into a recommendation to delete.
        let model = LeftoversModel()
        await model.load(service: LeftoversStub([
            leftover("orphan-a", .orphaned),
            leftover("orphan-b", .orphaned),
            leftover("mystery", .unclaimed)
        ]))

        XCTAssertEqual(model.orphaned.count, 2)
        XCTAssertEqual(model.unclaimed.count, 1)
        XCTAssertEqual(model.selection.count, 2)
        XCTAssertFalse(
            model.selection.contains(leftover("mystery", .unclaimed).id),
            "An unattributable item must never start selected"
        )
    }

    func testTheCategoriesAreKeptApart() async {
        let model = LeftoversModel()
        await model.load(service: LeftoversStub([
            leftover("orphan", .orphaned),
            leftover("mystery", .unclaimed)
        ]))

        XCTAssertTrue(model.orphaned.allSatisfy { $0.category == .orphaned })
        XCTAssertTrue(model.unclaimed.allSatisfy { $0.category == .unclaimed })
        XCTAssertTrue(
            Set(model.orphaned.map(\.id)).isDisjoint(with: model.unclaimed.map(\.id)),
            "No item may appear in both lists"
        )
    }

    func testSomethingBrimCannotRemoveIsNotPreSelected() async {
        // A sandbox container without Full Disk Access. Selecting it would
        // promise a removal that cannot happen.
        let model = LeftoversModel()
        await model.load(service: LeftoversStub([
            leftover("container", .orphaned, capability: .needsFullDiskAccess)
        ]))

        XCTAssertEqual(model.orphaned.count, 1, "It is still shown")
        XCTAssertTrue(model.selection.isEmpty, "But not offered as something Brim will remove")
    }

    func testWhatBrimCannotRemoveCannotBeTicked() async throws {
        let model = LeftoversModel()
        let blocked = leftover("container", .unclaimed, capability: .needsFullDiskAccess)
        await model.load(service: LeftoversStub([blocked]))

        let group = try XCTUnwrap(model.unclaimedGroups.first)
        model.toggle(group)

        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertFalse(
            model.canRemoveSelection,
            "Removal must be refused up front, not discovered as a failure afterwards"
        )
    }

    func testReviewAllSkipsWhatCannotBeRemoved() async {
        let model = LeftoversModel()
        let owner = Identity(bundleID: "com.example.removed", name: "Removed App")
        let items = [
            Leftover(url: URL(fileURLWithPath: "/tmp/leftovers/fine"), size: 100,
                     category: .orphaned, potentialOwner: owner),
            Leftover(url: URL(fileURLWithPath: "/tmp/leftovers/container"), size: 100,
                     category: .orphaned, potentialOwner: owner, capability: .needsFullDiskAccess)
        ]
        await model.load(service: LeftoversStub(items))

        model.selectAllRemovableOrphans()

        XCTAssertEqual(model.selection, [items[0].id])
        XCTAssertTrue(model.canRemoveSelection)
    }

    func testRemovalNamesTargetsRatherThanAnIdentity() async throws {
        // Leftovers have no owner by definition, so there is no footprint to
        // discover. Naming targets also keeps the planner out of whole-app
        // territory: it must not clear privacy grants or retract a
        // registration for software that is already gone.
        let model = LeftoversModel()
        await model.load(service: LeftoversStub([leftover("orphan", .orphaned)]))

        let intent = try XCTUnwrap(model.removalIntent(requesterIdentity: "tester"))
        XCTAssertEqual(intent.explicitTargets.count, 1)
        XCTAssertNil(intent.subjectIdentity.bundleID)
    }

    func testNothingSelectedMeansNothingToDo() async {
        let model = LeftoversModel()
        await model.load(service: LeftoversStub([leftover("mystery", .unclaimed)]))

        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertFalse(model.canRemoveSelection)
        XCTAssertNil(model.removalIntent(requesterIdentity: "tester"))
    }

    func testMixedGroupCanBeDeselectedWithoutSelectingBlockedItems() async throws {
        // A blocked location used to keep the whole card unchecked even
        // when every removable location was selected, so toggling could not clear it.
        let owner = Identity(bundleID: "com.example.removed", name: "Removed App")
        let items = [
            Leftover(url: URL(fileURLWithPath: "/tmp/leftovers/cache"), size: 100,
                     category: .orphaned, potentialOwner: owner),
            Leftover(url: URL(fileURLWithPath: "/tmp/leftovers/protected"), size: 100,
                     category: .orphaned, potentialOwner: owner, capability: .refusedByOS)
        ]
        let model = LeftoversModel()
        await model.load(service: LeftoversStub(items))
        let group = try XCTUnwrap(model.orphanedGroups.first)
        XCTAssertEqual(group.items.count, 2)
        XCTAssertTrue(model.isSelected(group))
        model.toggle(group)
        XCTAssertTrue(model.selection.isEmpty)
        model.toggle(group)
        XCTAssertEqual(model.selection, [items[0].id])
        let intent = try XCTUnwrap(model.removalIntent(for: group, requesterIdentity: "tester"))
        XCTAssertEqual(intent.explicitTargets, [items[0].url])
    }

    func testBatchIncludesHelperItemsAndRequiresExplicitUnknownSelection() async throws {
        let helper = Leftover(
            url: URL(fileURLWithPath: "/Library/LaunchAgents/com.example.removed.plist"),
            size: 100, category: .orphaned, capability: .needsHelper
        )
        let unknown = leftover("unknown", .unclaimed)
        let blocked = leftover("blocked", .orphaned, capability: .refusedByOS)
        let ordinary = leftover("ordinary", .orphaned)
        let model = LeftoversModel()
        await model.load(service: LeftoversStub([helper, unknown, blocked, ordinary]))
        let unknownGroup = try XCTUnwrap(model.unclaimedGroups.first { $0.items.contains { $0.id == unknown.id } })
        model.toggle(unknownGroup)
        model.selectAllRemovableOrphans()
        let batch = try XCTUnwrap(model.removalIntent(requesterIdentity: "tester"))
        XCTAssertEqual(Set(batch.explicitTargets), [helper.url, ordinary.url])
        model.toggle(unknownGroup)
        let selected = try XCTUnwrap(model.removalIntent(requesterIdentity: "tester"))
        XCTAssertEqual(Set(selected.explicitTargets), [helper.url, ordinary.url, unknown.url])
    }

    func testBatchKeepsFailedItemsSelectedForRetry() async throws {
        let removed = leftover("removed", .orphaned)
        let failed = leftover("failed", .orphaned)
        let model = LeftoversModel()
        await model.load(service: LeftoversStub([removed, failed]))
        model.forget(paths: [removed.url.path])
        XCTAssertEqual(model.all, [failed])
        XCTAssertEqual(model.selection, [failed.id])
        let retry = try XCTUnwrap(model.removalIntent(requesterIdentity: "tester"))
        XCTAssertEqual(retry.explicitTargets, [failed.url])
    }

    func testReviewAllLeavesOutUnknownItems() async throws {
        let removed = leftover("removed", .orphaned)
        let unknown = leftover("unknown", .unclaimed)
        let model = LeftoversModel()
        await model.load(service: LeftoversStub([removed, unknown]))
        model.deselectAll(in: model.all)
        model.selectAllRemovableOrphans()
        let intent = try XCTUnwrap(model.removalIntent(requesterIdentity: "tester"))
        XCTAssertEqual(intent.explicitTargets, [removed.url])
    }
}
