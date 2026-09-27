@testable import BrimService
import XCTest

/// The result says what happened, from what was recorded when it happened.
///
/// The incident: three links in `~/.local/bin` were skipped with
/// `needs_helper_not_set_up` written in the journal, and the result screen
/// said "Brim could not remove them and macOS did not say why", followed
/// by three bare names and no folder. The message was worked out again
/// after the fact from the folder's permissions, which allowed the removal,
/// so it had nothing to say. The journal knew exactly why.
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
        XCTAssertTrue(text.contains("helper"), text)
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

    func testAFolderIsNamedEvenWhenNothingIsKnown() {
        let text = BrimService.whyTheseRemain(paths(["tool"])) { _ in .ok }
        XCTAssertTrue(text.contains(folder), text)
    }
}
