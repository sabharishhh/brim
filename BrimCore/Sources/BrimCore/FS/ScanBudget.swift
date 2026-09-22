import Foundation

/// How long a scan is allowed to take, and what to say when it runs out.
///
/// Brim had bounded concurrency and no deadline discipline, which is a
/// different thing: concurrency stops the machine being overwhelmed, a
/// deadline stops one unreadable path holding up the whole run. A network
/// volume that has gone away, a directory behind a stalled file provider,
/// a FUSE mount whose daemon died: any of these can make a single
/// `contentsOfDirectory` take a minute, and there are sixty-odd locations
/// to visit.
///
/// The important part is not that it stops. It is what it says afterwards.
/// A scan that gave up halfway and reports a tidy list is worse than one
/// that took longer, because the list looks complete.
public struct ScanBudget: Sendable {
    /// When the whole run must be finished.
    public let deadline: Date
    /// The most any single probe may take. Derived from what is left, so
    /// a run already near its limit does not spend all of it in one
    /// directory.
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

    public var hasRunOut: Bool { Date() >= deadline }

    /// What a single probe may take now: whichever is smaller, its own
    /// allowance or whatever is left of the run.
    public var nextProbeAllowance: TimeInterval {
        max(0, min(perProbe, deadline.timeIntervalSinceNow))
    }
}

/// Whether a scan saw everything it set out to.
///
/// Mole degrades a timed-out ownership scan to `SCAN_PARTIAL` and narrows
/// the plan rather than deleting shared leftovers, and Brim's own
/// invariant says degrade, never fail. This is the concrete form: an
/// unfinished search is carried forward as a fact, and the safety engine
/// takes every affected item out of the default selection.
///
/// The rule is not "be careful when the scan was slow". It is that a
/// footprint is a claim about what is there, and an incomplete search
/// cannot support the claim, so nothing found in an unfinished pass may
/// be removed without somebody looking at it.
public struct ScanCompleteness: Sendable, Equatable, Codable {
    /// Locations that were not read, by path.
    public let unreadable: [String]
    /// Locations abandoned because the budget ran out.
    public let timedOut: [String]

    public init(unreadable: [String] = [], timedOut: [String] = []) {
        self.unreadable = unreadable
        self.timedOut = timedOut
    }

    public static let complete = ScanCompleteness()

    public var isComplete: Bool { unreadable.isEmpty && timedOut.isEmpty }

    /// What the person is told, or nil when there is nothing to tell.
    ///
    /// Both sentences have to carry the same two things: what is missing, and
    /// what to do about it. An earlier pair said only the first, and ended on
    /// "so nothing is selected for you", which reads as an apology for work
    /// Brim did not do rather than as a list of everything it did.
    public var explanation: String? {
        guard !isComplete else { return nil }
        if !timedOut.isEmpty {
            let count = timedOut.count
            return "\(count) \(count == 1 ? "place" : "places") took longer to read than the "
                 + "scan allows. Everything else is listed below. Run the scan again to "
                 + "include \(count == 1 ? "it" : "them")."
        }
        let count = unreadable.count
        return "\(count) \(count == 1 ? "place" : "places") on this Mac \(count == 1 ? "is" : "are") "
             + "closed to Brim. Everything else is listed below, and Full Disk Access opens "
             + "the rest."
    }

    public func merging(_ other: ScanCompleteness) -> ScanCompleteness {
        ScanCompleteness(
            unreadable: unreadable + other.unreadable,
            timedOut: timedOut + other.timedOut
        )
    }
}
