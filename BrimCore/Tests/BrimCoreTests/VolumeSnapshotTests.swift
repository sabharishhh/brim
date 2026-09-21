import XCTest
@testable import BrimCore

/// Snapshots are read for count and purgeability, never for size.
///
/// macOS exposes no supported way to ask how many bytes a snapshot holds.
/// `tmutil listlocalsnapshots` gives names only, `diskutil apfs
/// listSnapshots` adds whether each is disposable, and neither reports a
/// figure. The parser exists so the view can say what is known without
/// inventing what is not.
final class VolumeSnapshotTests: XCTestCase {

    func testAPinningSnapshotIsReadAsSuch() {
        // Real output from `diskutil apfs listSnapshots /`.
        let listing = """
        Snapshot for disk3s1s1 (1 found)
        |
        +-- A7AA2BFF-5387-43A6-B642-366BFC535E29
            Name:        com.apple.os.update-5203530F8BB2
            XID:         18027704
            Purgeable:   No
            NOTE:        This snapshot limits the minimum size of APFS Container disk3
        """
        let snapshots = VolumeAccountant.parseSnapshots(listing)

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].name, "com.apple.os.update-5203530F8BB2")
        XCTAssertFalse(snapshots[0].isPurgeable, "This is the kind that makes a deletion free nothing")
    }

    func testPurgeableAndPinningAreToldApart() {
        let listing = """
        Snapshot for disk1s1 (2 found)
        +-- AAA
            Name:        com.apple.TimeMachine.2026-09-21-010101.local
            Purgeable:   Yes
        +-- BBB
            Name:        com.apple.os.update-abc
            Purgeable:   No
        """
        let snapshots = VolumeAccountant.parseSnapshots(listing)

        XCTAssertEqual(snapshots.count, 2)
        let account = VolumeAccount(
            name: "Test", url: URL(fileURLWithPath: "/"), capacity: 100,
            freeRightNow: 40, reclaimableByTheSystem: 10,
            snapshots: snapshots, isRemovable: false
        )
        XCTAssertEqual(account.pinningSnapshots.count, 1)
        XCTAssertEqual(account.pinningSnapshots.first?.name, "com.apple.os.update-abc")
    }

    func testNoSnapshotsReadsAsNoneRatherThanFailing() {
        XCTAssertTrue(VolumeAccountant.parseSnapshots("Snapshots for disk /:").isEmpty)
        XCTAssertTrue(VolumeAccountant.parseSnapshots("").isEmpty)
    }

    func testASnapshotWithNoPurgeableLineIsTreatedAsPinning() {
        // The cautious reading: if macOS did not say it would discard it,
        // do not tell the user it will.
        let snapshots = VolumeAccountant.parseSnapshots("""
        +-- AAA
            Name:        com.apple.something
            XID:         12
        """)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertFalse(snapshots[0].isPurgeable)
    }

    func testTheThreeFiguresNeverOverlap() {
        let account = VolumeAccount(
            name: "Macintosh HD", url: URL(fileURLWithPath: "/"),
            capacity: 1000, freeRightNow: 400, reclaimableByTheSystem: 100,
            snapshots: [], isRemovable: false
        )
        XCTAssertEqual(account.used, 500)
        XCTAssertEqual(account.used + account.freeRightNow + account.reclaimableByTheSystem,
                       account.capacity, "The parts have to add up to the whole")
        XCTAssertEqual(account.freeAsFinderReportsIt, 500, "Finder counts the last two together")
    }
}
