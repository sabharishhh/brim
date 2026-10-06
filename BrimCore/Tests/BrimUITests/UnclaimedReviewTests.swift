import BrimCore
@testable import BrimUI
import Foundation
import Testing

/// Which unclaimed groups Remnants lists. A single small scrap stays out;
/// several of one developer's leftovers, with nothing of theirs installed,
/// are listed however small, because seven of Adobe's folders were each
/// under the megabyte line and none of them was shown.
@MainActor
struct UnclaimedReviewTests {
    private func item(_ name: String, bytes: Int64 = 4096, vendor: String? = nil) -> Leftover {
        var leftover = Leftover(url: URL(fileURLWithPath: "/Users/me/Library/HTTPStorages/\(name)"), size: bytes,
                                category: .unclaimed)
        leftover.vendor = vendor
        return leftover
    }

    @Test func `several small leftovers of one developer are listed`() {
        let group = LeftoverGroup(displayName: "Vendorco", identifier: nil,
                                  items: [item("com.vendorco.a", vendor: "com.vendorco"),
                                          item("com.vendorco.b", vendor: "com.vendorco")],
                                  groupKey: "vendor:com.vendorco")
        #expect(LeftoversModel.isWorthReview(group))
    }

    @Test func `a single small scrap stays out, a large one does not`() {
        let scrap = LeftoverGroup(displayName: "Thing", identifier: nil, items: [item("com.other.thing")],
                                  groupKey: "com.other.thing")
        #expect(LeftoversModel.isWorthReview(scrap) == false)
        let lone = LeftoverGroup(displayName: "Vendorco", identifier: nil,
                                 items: [item("com.vendorco.a", vendor: "com.vendorco")],
                                 groupKey: "vendor:com.vendorco")
        #expect(LeftoversModel.isWorthReview(lone) == false)
        let large = LeftoverGroup(displayName: "Thing", identifier: nil,
                                  items: [item("com.other.thing", bytes: 5_000_000)], groupKey: "com.other.thing")
        #expect(LeftoversModel.isWorthReview(large))
    }
}
