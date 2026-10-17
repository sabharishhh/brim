import BrimOps
@testable import BrimService
import XCTest

/// The result says what happened from what the journal recorded at the
/// time, not from permissions worked out again afterwards.
final class RecordedOutcomeCopyTests: XCTestCase {
    private let folder = "/Users/someone/.local/bin"

    private func paths(_ names: [String]) -> Set<String> {
        Set(names.map { "\(folder)/\($0)" })
    }

    func testTheRecordedReasonIsTheOneGiven() {
        let remaining = paths(["node", "npm", "npx"])
        let text = BrimService.whyTheseRemain(
            remaining,
            recorded: Dictionary(uniqueKeysWithValues: remaining.map { ($0, "needs_helper_not_set_up") })
        ) { _ in .ok }

        XCTAssertFalse(text.contains("did not say why"), text)
        XCTAssertTrue(text.contains("Administrator cleanup was unavailable"), text)
        XCTAssertTrue(text.contains("Review the removal again"), text)
        XCTAssertFalse(text.contains("turned on in Background"), text)
        XCTAssertTrue(text.contains(folder), "Where they are is part of the answer:\n\(text)")
        XCTAssertTrue(text.hasSuffix("node, npm, npx"), text)
    }

    func testTheHelpersOwnSentenceIsPassedOn() {
        let text = BrimService.whyTheseRemain(
            paths(["sh"]),
            recorded: ["\(folder)/sh": "helper_refused: It still leads to /bin/sh."]
        ) { _ in .needsHelper }
        XCTAssertTrue(text.contains("It still leads to /bin/sh."), text)
    }

    /// Preferences removed and written back empty by `cfprefsd` are said to have
    /// been written back.
    func testSomethingWrittenBackIsSaidToHaveBeenWrittenBack() {
        let text = BrimService
            .whyTheseRemain(paths(["prefs.plist"]), recorded: ["\(folder)/prefs.plist": "ok"]) { _ in .ok }
        XCTAssertTrue(text.contains("wrote it back"), text)
        XCTAssertFalse(text.contains("nothing was recorded"), text)
    }

    /// Only an empty preference file counts as the daemon's stub.
    func testOnlyAnEmptyPreferenceFileCountsAsTheDaemonsStub() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let empty = folder.appendingPathComponent("empty.plist")
        let full = folder.appendingPathComponent("full.plist")
        try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
            .write(to: empty)
        try PropertyListSerialization.data(fromPropertyList: ["k": 1], format: .binary, options: 0).write(to: full)
        XCTAssertTrue(PreferenceDomains.isEmptyStub(atPath: empty.path))
        XCTAssertFalse(PreferenceDomains.isEmptyStub(atPath: full.path))
        XCTAssertFalse(PreferenceDomains.isEmptyStub(atPath: folder.appendingPathComponent("absent.plist").path))
    }

    func testAFolderIsNamedEvenWhenNothingIsKnown() {
        let text = BrimService.whyTheseRemain(paths(["tool"])) { _ in .ok }
        XCTAssertTrue(text.contains(folder), text)
    }
}
