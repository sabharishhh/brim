@testable import BrimUI
import XCTest

/// The first sentence anybody reads in Brim may only say what was measured.
final class HomeHeadlineTests: XCTestCase {
    func testNothingIsClaimedBeforeTheFirstScanFinishes() {
        // The old header printed a confident "Empty" seconds before the real
        // figure arrived. A zero nobody measured is the number this product
        // must never print.
        let sentence = HomeHeadline.sentence(.init(hasChecked: false, isChecking: true))
        XCTAssertFalse(sentence.contains("Nothing"))
        XCTAssertTrue(sentence.contains("looking"))
    }

    func testAnUnreadableLibraryIsNotAnEmptyOne() {
        let sentence = HomeHeadline.sentence(.init(hasChecked: true, canSeeLibrary: false))
        XCTAssertEqual(sentence, "Brim cannot see most of this Mac yet.")
    }

    func testRemovedAppsLeadAndReadAsAPersonWouldWriteThem() {
        let sentence = HomeHeadline.sentence(.init(
            removedApps: 4, removedAppBytes: 2_100_000_000, unclaimed: 90, hasChecked: true
        ))
        XCTAssertTrue(sentence.hasPrefix("Four apps you removed left "), sentence)
        XCTAssertEqual(
            HomeHeadline.sentence(.init(removedApps: 1, removedAppBytes: 1, hasChecked: true)).prefix(7), "One app"
        )
        XCTAssertTrue(HomeHeadline.sentence(.init(removedApps: 14, hasChecked: true)).hasPrefix("14 apps"))
        XCTAssertTrue(
            HomeHeadline.sentence(.init(unclaimed: 94, unclaimedBytes: 4_630_000_000, hasChecked: true))
                .hasSuffix("94 leftovers no app claims take up 4.63 GB."), "Counts as the Leftovers list does"
        )
    }
}
