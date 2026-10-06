import BrimCore
import Foundation

extension LeftoversModel {
    /// Unclaimed groups worth a person's time: a megabyte or more, anything
    /// Brim cannot take or measure, and a developer's leftovers when there
    /// are several and nothing of theirs is installed. A single small scrap
    /// stays out, which is what the size line is for; seven of one
    /// developer's folders are a finding however small each is.
    static func isWorthReview(_ group: LeftoverGroup) -> Bool {
        group.totalBytes >= 1_000_000 || group.items.contains { $0.capability != .ok || $0.sizeIsKnown == false }
            || (group.groupKey.hasPrefix("vendor:") && group.items.count >= 2)
    }
}
