import BrimCore
@testable import BrimService
import XCTest

/// What Brim says when a removal did not go through: which items and why,
/// grouped so one reason shared by many items is said once.
final class RefusalCopyTests: XCTestCase {
    /// CI's `/usr/local/bin` is writable, so the measured state is supplied.
    private func explanation(_ paths: Set<String>) -> String {
        BrimService.whyTheseRemain(paths) { path in
            path.hasPrefix("/usr/local/bin/") ? .needsHelper : .ok
        }
    }

    private func fourteenInOneFolder() -> Set<String> {
        Set((1 ... 14).map { "/usr/local/bin/tool-\($0)" })
    }

    func testOneReasonIsGivenOnceHoweverManyThingsShareIt() {
        let text = explanation(fourteenInOneFolder())
        let sentence = "belongs to the system. Removing anything in it needs an administrator"
        XCTAssertEqual(
            text.components(separatedBy: sentence).count - 1, 1,
            "The reason holds for all fourteen and is worth saying once:\n\(text)"
        )
    }

    func testItOpensWithWhatHappenedAndEndsWithWhichThings() {
        let text = explanation(fourteenInOneFolder())
        XCTAssertTrue(text.hasPrefix("14 things are still there."), text)
        XCTAssertTrue(text.contains("/usr/local/bin"), "The folder they share is named:\n\(text)")
        XCTAssertTrue(text.contains("tool-1, tool-10"), "Each one is still named:\n\(text)")
    }

    /// Short enough for the panel that shows it.
    func testTheRefusalFitsInThePanelThatShowsIt() {
        let text = explanation(fourteenInOneFolder())
        XCTAssertLessThan(text.count, 400, text)
    }

    func testOneThingKeepsItsOwnSentence() {
        let text = explanation(["/usr/local/bin/zed"])
        XCTAssertTrue(text.hasPrefix("One thing is still there."), text)
        XCTAssertTrue(text.contains("/usr/local/bin belongs to the system"), text)
        XCTAssertTrue(text.hasSuffix("zed"), text)
    }

    /// Two folders are two answers with different remedies.
    func testDifferentReasonsStayApart() {
        let text = explanation([
            "/usr/local/bin/zed",
            "/usr/local/bin/docker",
            "\(NSHomeDirectory())/Library/Caches/thing"
        ])
        XCTAssertTrue(text.hasPrefix("3 things are still there."), text)
        XCTAssertTrue(text.contains("zed"), text)
        XCTAssertTrue(text.contains("thing"), text)
    }
}
