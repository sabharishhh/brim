@testable import BrimUI
import XCTest

/// A Home card may only say what was measured.
final class HomeStatusTests: XCTestCase {
    func testUnreadableBackgroundSurfaceDoesNotClaimAnEmptyList() {
        let summary = HomeStatus.background(leftOver: 0, hasChecked: true, hasFaults: true)
        XCTAssertEqual(summary.status, .partial)
        XCTAssertEqual(summary.phrase, "Partial view")
    }

    func testNothingIsClearBeforeTheScanFinishes() {
        // The old header printed a confident "Empty" seconds before the real
        // figure arrived. A zero nobody measured is the number this product
        // must never print.
        XCTAssertEqual(HomeStatus.leftovers(.init(hasChecked: false)).status, .checking)
        XCTAssertEqual(HomeStatus.background(leftOver: 0, hasChecked: false).status, .checking)
    }

    func testAnUnreadableLibraryIsPartialNotClear() {
        XCTAssertEqual(HomeStatus.leftovers(.init(hasChecked: true, canSeeLibrary: false)).status, .partial)
    }

    func testRemovedAppsAreWhatNeedsALook() {
        let result = HomeStatus.leftovers(.init(removedApps: 4, unclaimed: 90, hasChecked: true))
        XCTAssertEqual(result.status, .attention)
        XCTAssertEqual(result.phrase, "From 4 removed apps")
    }
}
