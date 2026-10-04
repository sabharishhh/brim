import BrimCore
import Foundation

// swiftformat:disable wrapMultilineStatementBraces

/// The state a Home card shows as a dot and a short phrase.
public enum CardStatus: Equatable, Sendable {
    /// Brim has not finished looking. No dot.
    case checking
    /// Looked, and nothing needs the person.
    case clear
    /// Looked, and something is worth a look.
    case attention
    /// Could not see everything, so the numbers are low.
    case partial
    /// Findings that are informational rather than a problem.
    case neutral
}

/// What each Home card says, in a few words.
///
/// A card never claims a result nobody measured: until its scan finishes it
/// says it is checking, and without Full Disk Access Leftovers says its view
/// is partial rather than clear, because an unreadable Library is not an
/// empty one.
public enum HomeStatus {
    public struct Leftovers: Equatable, Sendable {
        public var removedApps: Int
        /// Counted as the Leftovers list counts its rows.
        public var unclaimed: Int
        public var hasChecked: Bool
        public var canSeeLibrary: Bool

        public init(removedApps: Int = 0, unclaimed: Int = 0, hasChecked: Bool, canSeeLibrary: Bool = true) {
            self.removedApps = removedApps
            self.unclaimed = unclaimed
            self.hasChecked = hasChecked
            self.canSeeLibrary = canSeeLibrary
        }
    }

    public static func leftovers(_ facts: Leftovers) -> (status: CardStatus, phrase: String) {
        guard facts.hasChecked else { return (.checking, "Checking") }
        if facts.removedApps > 0 {
            let apps = facts.removedApps == 1 ? "1 removed app" : "\(facts.removedApps) removed apps"
            return (.attention, "From \(apps)")
        }
        guard facts.canSeeLibrary else { return (.partial, "Partial view") }
        if facts.unclaimed > 0 {
            return (.neutral, "\(facts.unclaimed) unclaimed")
        }
        return (.clear, "Nothing left behind")
    }

    public static func background(leftOver: Int, hasChecked: Bool, hasFaults: Bool = false)
        -> (status: CardStatus, phrase: String) {
        guard hasChecked else { return (.checking, "Checking") }
        guard !hasFaults else { return (.partial, "Partial view") }
        if leftOver > 0 {
            return (.attention, "\(leftOver) left over")
        }
        return (.clear, "No missing targets found")
    }
}
