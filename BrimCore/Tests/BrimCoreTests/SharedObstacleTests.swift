import XCTest
@testable import BrimCore

/// What a group says when Brim cannot remove any of it. The obstacle belongs
/// to the group because the remedy does: one reason, one folder, one trip to
/// Finder, with the files selected so one password prompt covers them. The
/// rows here sit in a root-owned folder the administrator process does not
/// touch.
final class SharedObstacleTests: XCTestCase {

    private func leftover(_ name: String, _ capability: Capability) -> Leftover {
        Leftover(
            url: URL(fileURLWithPath: "/Library/Application Support/PythonT/\(name)"),
            size: 0,
            category: .orphaned,
            potentialOwner: Identity(bundleID: nil, name: "PythonT.framework"),
            evidence: "because",
            capability: capability,
            lastAccessed: nil
        )
    }

    private func group(_ items: [Leftover]) -> LeftoverGroup {
        LeftoverGroup(
            displayName: "PythonT.framework", identifier: nil,
            items: items, groupKey: "pythont.framework"
        )
    }

    func testOneObstacleSharedByEveryItemIsTheGroupsToSay() {
        let blocked = group([
            leftover("python3t", .needsHelper),
            leftover("python3t-config", .needsHelper),
            leftover("python3t-intel64", .needsHelper),
        ])
        XCTAssertEqual(blocked.sharedObstacle, .needsHelper)
        XCTAssertFalse(blocked.isFullyActionable)
    }

    /// Said by the rows instead, because one sentence cannot cover two remedies.
    func testAMixedGroupHasNothingToSayAtTheTop() {
        XCTAssertNil(group([
            leftover("python3t", .needsHelper),
            leftover("other", .needsFullDiskAccess),
        ]).sharedObstacle)
    }

    func testAGroupWithOneBlockedItemAmongGoodOnesSaysNothingAtTheTop() {
        XCTAssertNil(group([
            leftover("python3t", .needsHelper),
            leftover("fine", .ok),
        ]).sharedObstacle)
    }

    /// A removable group has no obstacle panel.
    func testAGroupBrimCanRemoveHasNoObstacle() {
        let fine = group([leftover("a", .ok), leftover("b", .ok)])
        XCTAssertNil(fine.sharedObstacle)
        XCTAssertTrue(fine.isFullyActionable)
    }
}
