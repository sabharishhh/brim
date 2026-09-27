import BrimCore
import Foundation

/// The one sentence at the top of Home.
///
/// Filled in from a template, never written by a model (`CLAUDE.md`, on
/// C-4): every word of it is a count or a size Brim measured. And it never
/// states a zero it did not measure. Before the first scan finishes it says
/// Brim is looking; without Full Disk Access it says Brim cannot see most
/// of the Mac, rather than "Nothing is left behind" over a Library it could
/// not read.
public enum HomeHeadline {
    public struct Facts: Equatable, Sendable {
        /// Owners recorded on this Mac whose app is gone.
        public var removedApps: Int
        public var removedAppBytes: Int64
        /// Leftovers nothing installed claims, counted as the Leftovers
        /// list counts its rows, so the two screens give one number.
        public var unclaimed: Int
        public var unclaimedBytes: Int64
        public var hasChecked: Bool
        public var isChecking: Bool
        public var canSeeLibrary: Bool
        public var failed: Bool

        public init(
            removedApps: Int = 0, removedAppBytes: Int64 = 0, unclaimed: Int = 0, unclaimedBytes: Int64 = 0,
            hasChecked: Bool, isChecking: Bool = false, canSeeLibrary: Bool = true, failed: Bool = false
        ) {
            self.removedApps = removedApps
            self.removedAppBytes = removedAppBytes
            self.unclaimed = unclaimed
            self.unclaimedBytes = unclaimedBytes
            self.hasChecked = hasChecked
            self.isChecking = isChecking
            self.canSeeLibrary = canSeeLibrary
            self.failed = failed
        }
    }

    public static func sentence(_ facts: Facts) -> String {
        if facts.failed, !facts.hasChecked {
            return "Brim could not finish looking at this Mac."
        }
        guard facts.hasChecked else {
            return "Brim is looking at what software has left on this Mac."
        }
        if facts.removedApps > 0 {
            let apps = facts.removedApps == 1 ? "One app" : "\(count(facts.removedApps)) apps"
            return "\(apps) you removed left \(ByteText.short(facts.removedAppBytes)) behind."
        }
        if facts.unclaimed > 0 {
            let leftovers = facts.unclaimed == 1
                ? "One leftover no app claims takes"
                : "\(count(facts.unclaimed)) leftovers no app claims take"
            return "Nothing is left from apps you removed. \(leftovers) up \(ByteText.short(facts.unclaimedBytes))."
        }
        guard facts.canSeeLibrary else {
            return "Brim cannot see most of this Mac yet."
        }
        return "Nothing is left behind."
    }

    /// Spelled out up to ten, as a person would write it: "Four apps".
    static func count(_ number: Int, capitalised: Bool = true) -> String {
        guard (2 ... 10).contains(number) else { return "\(number)" }
        let words = ["two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        let word = words[number - 2]
        return capitalised ? word.prefix(1).uppercased() + word.dropFirst() : word
    }
}
