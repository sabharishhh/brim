import XCTest
@testable import BrimCore

/// What a group says when Brim cannot remove any of it.
///
/// Brim's root daemon is deliberately confined to job files in the two
/// machine-wide launchd folders, so a broken command in `/usr/local/bin` is
/// not Brim's to take. Finder can take it, and the person has already been
/// shown the lock. What they need next is the files, selected, so one
/// password prompt covers all of them: opening the folder and leaving
/// somebody to find six names among twenty-seven is not help.
///
/// The obstacle belongs to the group because the remedy does. Six broken
/// Python shims share one reason, one folder and one trip to Finder.
final class SharedObstacleTests: XCTestCase {

    private func leftover(_ name: String, _ capability: Capability) -> Leftover {
        Leftover(
            url: URL(fileURLWithPath: "/usr/local/bin/\(name)"),
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

    /// Said by the rows instead, because one sentence cannot cover two
    /// different remedies.
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

    /// A removable group must not grow an orange panel explaining a problem
    /// it does not have.
    func testAGroupBrimCanRemoveHasNoObstacle() {
        let fine = group([leftover("a", .ok), leftover("b", .ok)])
        XCTAssertNil(fine.sharedObstacle)
        XCTAssertTrue(fine.isFullyActionable)
    }
}
