import Foundation

/// How long a scan may take, and what to say when it runs out. A stalled
/// network volume or file provider can make one directory take a minute;
/// the deadline stops it holding up the run, and the run then says it is
/// incomplete rather than looking complete.
public struct ScanBudget: Sendable {
    /// When the whole run must be finished.
    public let deadline: Date
    /// The most any single probe may take, derived from what is left so one
    /// directory cannot spend the whole run.
    public let perProbe: TimeInterval

    public init(
        total: TimeInterval = 20,
        perProbe: TimeInterval = 2,
        now: Date = Date()
    ) {
        self.deadline = now.addingTimeInterval(total)
        self.perProbe = perProbe
    }

    /// A budget with no limit, for tests and for the shadow tree.
    public static var unlimited: ScanBudget {
        ScanBudget(total: .greatestFiniteMagnitude, perProbe: .greatestFiniteMagnitude)
    }

    public var hasRunOut: Bool {
        Task.isCancelled || Date() >= deadline
    }

    /// What a single probe may take now: whichever is smaller, its own
    /// allowance or whatever is left of the run.
    public var nextProbeAllowance: TimeInterval {
        max(0, min(perProbe, deadline.timeIntervalSinceNow))
    }
}

/// Whether a scan saw everything it set out to. A footprint is a claim about
/// what is on the disk, and an unfinished search cannot support it, so the
/// safety engine takes every affected item out of the default selection.
public struct ScanCompleteness: Sendable, Equatable, Codable {
    /// Locations that were not read, by path.
    public let unreadable: [String]
    /// Locations abandoned because the budget ran out.
    public let timedOut: [String]

    public init(unreadable: [String] = [], timedOut: [String] = []) {
        self.unreadable = Array(Set(unreadable)).sorted()
        self.timedOut = Array(Set(timedOut)).sorted()
    }

    public static let complete = ScanCompleteness()

    public var isComplete: Bool { unreadable.isEmpty && timedOut.isEmpty }

    /// A read failure can have several causes; do not promise that a permission fixes it.
    public var explanation: String? {
        guard !isComplete else { return nil }
        var reasons: [String] = []
        if !unreadable.isEmpty {
            reasons.append("Could not read \(unreadable.count) \(unreadable.count == 1 ? "place" : "places").")
        }
        if !timedOut.isEmpty {
            reasons.append("The scan timed out in \(timedOut.count) \(timedOut.count == 1 ? "place" : "places").")
        }
        return (reasons + ["Review the available items or scan again."]).joined(separator: " ")
    }

    public func merging(_ other: ScanCompleteness) -> ScanCompleteness {
        ScanCompleteness(
            unreadable: unreadable + other.unreadable,
            timedOut: timedOut + other.timedOut
        )
    }
}
