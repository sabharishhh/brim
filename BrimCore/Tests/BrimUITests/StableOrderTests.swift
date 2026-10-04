@testable import BrimUI
import XCTest

/// Rows hold their places for a visit, and new ones join at the end.
final class StableOrderTests: XCTestCase {
    private struct Row: Identifiable, Equatable {
        let id: String
    }

    private func group(_ ids: [String]) -> ItemGroup<Row> {
        ItemGroup(id: "g", title: "G", items: ids.map(Row.init))
    }

    /// A rescan that re-sorts by size moved the row under the pointer, and
    /// the next click ticked its neighbour.
    func testARescanDoesNotReorderWhatIsShowing() {
        let before = StableOrder.positions([group(["a", "b", "c"])])
        let rescanned = [group(["c", "a", "b"])]

        let shown = StableOrder.apply(rescanned, remembered: before)

        XCTAssertEqual(shown.first?.items.map(\.id), ["a", "b", "c"])
    }

    func testWhatArrivedSinceGoesAtTheEndOfItsGroup() {
        let before = StableOrder.positions([group(["a", "b"])])
        let shown = StableOrder.apply([group(["new", "b", "a"])], remembered: before)

        XCTAssertEqual(shown.first?.items.map(\.id), ["a", "b", "new"])
    }

    func testNothingRememberedChangesNothing() {
        let shown = StableOrder.apply([group(["b", "a"])], remembered: [:])
        XCTAssertEqual(shown.first?.items.map(\.id), ["b", "a"])
    }
}
