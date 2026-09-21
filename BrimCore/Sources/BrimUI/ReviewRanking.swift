import Foundation

/// What to put at the top of the landing screen.
///
/// The areas were listed in a fixed order, so the first thing on screen
/// was whatever the code happened to declare first. On a Mac with nothing
/// left over and forty gigabytes of build caches, that led with Leftovers
/// and its zero.
///
/// Ranked by how much there is to act on: how sure the finding is,
/// multiplied by what acting on it is worth. Nothing about the ranking is
/// shown. There is no score, no percentage and no health colour, because
/// a number a person cannot check is a number they have to take on trust,
/// and this product's whole argument is that they should not have to.
/// Only the order changes.
public struct ReviewRanking: Sendable {

    /// How sure a finding of this kind is, between nothing and certain.
    ///
    /// Not a guess dressed as arithmetic: each of these corresponds to an
    /// evidence tier the scanner already assigns. An orphan names the
    /// record that named its owner. An unclaimed file matches a name.
    /// A build cache is a cache by definition.
    public enum Confidence: Double, Sendable {
        /// The thing itself says so: a cache directory, a receipt.
        case certain = 1.0
        /// A record names it, and the record is gone.
        case named = 0.9
        /// A strong convention, short of proof.
        case likely = 0.6
        /// A name match.
        case possible = 0.4
        /// Nothing to act on; here to be looked at.
        case informational = 0.05
    }

    public struct Finding: Equatable, Sendable {
        public let area: String
        /// What acting on this returns, where that is bytes.
        public let bytes: Int64
        /// How many things there are, where bytes do not apply.
        public let count: Int
        public let confidence: Double
        /// Still scanning. Ranked as if it will find something, so an area
        /// does not jump to the top the moment it finishes.
        public let isWorking: Bool

        public init(
            area: String, bytes: Int64 = 0, count: Int = 0,
            confidence: Confidence, isWorking: Bool = false
        ) {
            self.area = area
            self.bytes = bytes
            self.count = count
            self.confidence = confidence.rawValue
            self.isWorking = isWorking
        }

        /// Confidence times impact.
        ///
        /// Bytes where there are bytes, because a gigabyte is the thing
        /// people came for. Where there are none, each item counts for a
        /// nominal amount so that ten stale background jobs outrank one,
        /// and neither outranks a real gigabyte.
        public var weight: Double {
            let impact = bytes > 0 ? Double(bytes) : Double(count) * 8_000_000
            return impact * confidence
        }
    }

    /// Highest first, and anything with nothing to act on keeps its
    /// declared order at the bottom rather than shuffling about.
    public static func rank(_ findings: [Finding]) -> [Finding] {
        let ordered = findings.enumerated().sorted { left, right in
            let a = left.element, b = right.element
            if a.weight != b.weight { return a.weight > b.weight }
            // A stable tie-break, so two empty areas do not swap places
            // between one redraw and the next.
            return left.offset < right.offset
        }
        return ordered.map(\.element)
    }
}
