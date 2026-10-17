import BrimCore
import Foundation

extension LeftoversModel {
    /// Unclaimed groups worth a person's time: a megabyte or more, anything Brim
    /// cannot take or measure, and a developer's several leftovers when nothing
    /// of theirs is installed. A single small scrap stays out.
    static func isWorthReview(_ group: LeftoverGroup) -> Bool {
        group.totalBytes >= 1_000_000 || group.items.contains { $0.capability != .ok || $0.sizeIsKnown == false }
            || (group.groupKey.hasPrefix("vendor:") && group.items.count >= 2)
    }
}
