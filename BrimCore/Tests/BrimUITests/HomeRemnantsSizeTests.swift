import BrimCore
import BrimUI
import XCTest

final class HomeRemnantsSizeTests: XCTestCase {
    func testUnknownItemsAreAReviewCountRatherThanAnEmptyClaim() {
        XCTAssertEqual(HomeRemnantsSize(groups: [], unclaimed: 3).figure, "3 to review")
    }

    func testUnclaimedProtectedStorageCannotHideMeasuredRemovedApps() {
        let items = [
            Leftover(url: URL(fileURLWithPath: "/tmp/removed/settings"), size: 2048,
                     category: .orphaned),
            Leftover(url: URL(fileURLWithPath: RecoveryCopy.directory), size: 0,
                     category: .unclaimed, capability: .needsHelper, sizeIsKnown: false)
        ]
        // Home's size describes removed apps, not unrelated protected storage.
        let groups = items.filter { $0.category == .orphaned }.groupedByOwner()
        let summary = HomeRemnantsSize(groups: groups)
        XCTAssertEqual(summary.bytes, 2048)
        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(summary.figure, ByteText.short(2048))
    }

    func testUnreadableRemovedAppLocationsRemainAPartialSize() {
        let item = Leftover(url: URL(fileURLWithPath: "/tmp/removed/cache"), size: 1024,
                            category: .orphaned, sizeIsKnown: false)
        let summary = HomeRemnantsSize(groups: [item].groupedByOwner())
        XCTAssertFalse(summary.isComplete)
        XCTAssertEqual(summary.figure, "At least " + ByteText.short(1024))
    }

    func testAnUnreadableZeroIsNotAnEmptyMeasuredResult() {
        let item = Leftover(url: URL(fileURLWithPath: "/tmp/removed/cache"), size: 0,
                            category: .orphaned, sizeIsKnown: false)
        XCTAssertEqual(HomeRemnantsSize(groups: [item].groupedByOwner()).figure, "Size unavailable")
        XCTAssertTrue(HomeRemnantsSize(groups: []).isComplete)
    }
}
