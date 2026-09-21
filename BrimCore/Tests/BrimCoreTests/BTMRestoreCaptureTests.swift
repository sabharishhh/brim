import XCTest
import BrimCore
@testable import BrimScan

/// Writing down what is registered, and knowing when the list is short.
///
/// `BTMStore.records()` returns nil when the store could not be read,
/// which is a different answer from an empty list and almost always means
/// Full Disk Access is off. A capture that treated them the same would
/// produce an empty restore list, the reset would look safe, and the
/// person would discover what they lost when things stopped starting.
final class BTMRestoreCaptureTests: XCTestCase {

    private static func record(
        name: String?, disposition: String? = nil, path: String? = "/Applications/Thing.app"
    ) -> BTMRecord {
        BTMRecord(
            uuid: UUID().uuidString, name: name, developerName: "Someone",
            type: "login item", disposition: disposition, identifier: "id.\(name ?? "x")",
            rawURLPath: path, bundleIdentifier: "com.example.\(name ?? "x")"
        )
    }

    func testAnUnreadableStoreIsIncompleteRatherThanEmpty() {
        let capture = BTMRestoreCapture(read: { nil })
        let list = capture.capture()

        XCTAssertFalse(list.isComplete)
        XCTAssertTrue(list.entries.isEmpty)
        XCTAssertFalse(list.canSupportAReset, "An unreadable store must not permit a reset")
        XCTAssertTrue(list.gap?.contains("Full Disk Access") ?? false)
    }

    func testAGenuinelyEmptyStoreIsCompleteAndStillCannotSupportAReset() {
        let list = BTMRestoreCapture(read: { [] }).capture()

        XCTAssertTrue(list.isComplete)
        XCTAssertFalse(list.canSupportAReset, "There is nothing to reset")
        XCTAssertTrue(list.summary.contains("nothing to reset"))
    }

    func testEverythingRegisteredIsWrittenDown() {
        let list = BTMRestoreCapture(read: {
            [Self.record(name: "Zed"), Self.record(name: "Alpha")]
        }).capture()

        XCTAssertTrue(list.isComplete)
        XCTAssertTrue(list.canSupportAReset)
        XCTAssertEqual(list.entries.map(\.name), ["Alpha", "Zed"], "Sorted, so it reads as a list")
        XCTAssertEqual(list.entries.first?.bundleIdentifier, "com.example.Alpha")
    }

    func testAnUnnamedItemStillGetsALine() {
        // A row with no name is exactly the one a person will struggle to
        // find again, so it falls back to something identifying rather
        // than being dropped.
        let list = BTMRestoreCapture(read: { [Self.record(name: nil)] }).capture()
        XCTAssertEqual(list.entries.count, 1)
        XCTAssertFalse(list.entries[0].name.isEmpty)
    }

    func testARelativePathIsNotWrittenDownAsIfItWereReal() {
        // An embedded helper's URL is relative to its parent bundle.
        // Resolving it as absolute produces a path under the working
        // directory that does not exist, and a restore list is read hours
        // later by a person with no parent to hand.
        let list = BTMRestoreCapture(read: {
            [Self.record(name: "Helper", path: "Contents/Library/LoginItems/Helper.app")]
        }).capture()

        XCTAssertEqual(list.entries.count, 1)
        XCTAssertNil(list.entries[0].path)
        XCTAssertEqual(list.entries[0].name, "Helper", "It is still listed, just without a path")
    }

    func testWhatWasSwitchedOffStaysSwitchedOff() {
        // Re-enabling something the person had deliberately turned off
        // would be its own small betrayal.
        let list = BTMRestoreCapture(read: {
            [
                Self.record(name: "On", disposition: "1"),
                Self.record(name: "Off", disposition: "2"),
            ]
        }).capture()

        XCTAssertEqual(list.entries.first(where: { $0.name == "On" })?.wasEnabled, true)
        XCTAssertEqual(list.entries.first(where: { $0.name == "Off" })?.wasEnabled, false)
    }

    func testTheSummaryCountsWhatIsSwitchedOn() {
        let list = BTMRestoreCapture(read: {
            [
                Self.record(name: "A", disposition: "1"),
                Self.record(name: "B", disposition: "2"),
                Self.record(name: "C", disposition: "1"),
            ]
        }).capture()

        XCTAssertTrue(list.summary.contains("3 background items"), list.summary)
        XCTAssertTrue(list.summary.contains("2 of 3"), list.summary)
    }
}
