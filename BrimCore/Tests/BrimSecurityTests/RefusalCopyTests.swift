import XCTest
import BrimCore
@testable import BrimService

/// What Brim says when a removal did not go through.
///
/// This has been wrong in both directions. First it was "2 targets still
/// remain": a count, naming neither which two nor why, for a case where the
/// answer was that both sat in a root-owned directory and no amount of
/// retrying would have helped.
///
/// The fix overcorrected. Naming every item and repeating its reason
/// produced, for fourteen broken commands in one folder, fourteen copies of
/// the same sentence run together into a single paragraph: nine hundred
/// characters of which eight hundred were duplicates, and the panel showing
/// it clipped the rest mid-word behind an ellipsis with no way to scroll.
/// One reason held for all fourteen and the shape of the text hid that
/// completely.
final class RefusalCopyTests: XCTestCase {

    // CI's /usr/local/bin is writable. Copy tests supply the measured state
    // instead of assuming the test machine has the developer's permissions.
    private func explanation(_ paths: Set<String>) -> String {
        BrimService.whyTheseRemain(paths) { path in
            path.hasPrefix("/usr/local/bin/") ? .needsHelper : .ok
        }
    }

    private func fourteenInOneFolder() -> Set<String> {
        Set((1...14).map { "/usr/local/bin/tool-\($0)" })
    }

    func testOneReasonIsGivenOnceHoweverManyThingsShareIt() {
        let text = explanation(fourteenInOneFolder())
        let sentence = "belongs to the system, so removing anything in it needs an administrator"
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

    /// Short enough to read in the space it is shown in. The old one was
    /// nine hundred characters for this input and was cut off.
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

    /// Two folders are two answers, and collapsing them would hide that one
    /// of them is a different problem with a different remedy.
    func testDifferentReasonsStayApart() {
        let text = explanation([
            "/usr/local/bin/zed",
            "/usr/local/bin/docker",
            "\(NSHomeDirectory())/Library/Caches/thing",
        ])
        XCTAssertTrue(text.hasPrefix("3 things are still there."), text)
        XCTAssertTrue(text.contains("zed"), text)
        XCTAssertTrue(text.contains("thing"), text)
    }
}
