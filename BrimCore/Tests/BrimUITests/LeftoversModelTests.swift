import XCTest
import BrimCore
import BrimProtocol
@testable import BrimUI

private actor LeftoversStub: BrimServiceProtocol {
    let items: [Leftover]
    init(_ items: [Leftover]) { self.items = items }
    func leftovers() async throws -> [Leftover] { items }

    func inspect(identity: Identity) async throws -> Footprint { throw Nope.no }
    func plan(intent: PlanIntent) async throws -> Plan { throw Nope.no }
    func explain(planId: UUID) async throws -> String { throw Nope.no }
    func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalRequestReceipt { throw Nope.no }
    func apply(planId: UUID, token: ApprovalToken) async throws { throw Nope.no }
    func verify(planId: UUID) async throws -> VerificationResult { throw Nope.no }
    func history() async throws -> [Plan] { [] }
    func undo(planId: UUID) async throws { throw Nope.no }
    func dumpBTM() async throws -> String { "" }
    func installedApplications() async throws -> [InstalledApplication] { [] }
    func recoverableItems() async throws -> [RecoverableItem] { [] }
    func scanDuplicates(in directory: URL) async throws -> [DuplicateGroup] { [] }
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

    func testOnlyOrphansArePreSelected() async {
        // The whole point of the two-category model. An unclaimed item is
        // one the search could not attribute — pre-selecting it would turn
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

    func testABlockedSelectionIsSurfacedRatherThanAttempted() async {
        let model = LeftoversModel()
        let blocked = leftover("container", .unclaimed, capability: .needsFullDiskAccess)
        await model.load(service: LeftoversStub([blocked]))

        model.toggle(blocked)

        XCTAssertEqual(model.blockedSelection.count, 1)
        XCTAssertFalse(
            model.canRemoveSelection,
            "Removal must be refused up front, not discovered as a failure afterwards"
        )
    }

    func testSelectAllSkipsWhatCannotBeRemoved() async {
        let model = LeftoversModel()
        let items = [
            leftover("fine", .unclaimed),
            leftover("container", .unclaimed, capability: .needsFullDiskAccess)
        ]
        await model.load(service: LeftoversStub(items))

        model.selectAll(in: model.unclaimed)

        XCTAssertEqual(model.selection.count, 1)
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

    func testSearchFiltersWithoutChangingSelection() async {
        let model = LeftoversModel()
        await model.load(service: LeftoversStub([
            leftover("figma-cache", .orphaned),
            leftover("sketch-cache", .orphaned)
        ]))
        let before = model.selection

        model.searchText = "figma"

        XCTAssertEqual(model.visible(model.orphaned).count, 1)
        XCTAssertEqual(model.selection, before, "Filtering the view must not silently deselect")
    }
}
