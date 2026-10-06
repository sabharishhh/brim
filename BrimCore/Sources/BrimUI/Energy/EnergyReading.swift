import BrimCore
import Foundation

public extension EnergyModel {
    /// One application, measured across the gap between two samples.
    ///
    /// An application, not a process. A modern Mac app is a crowd of them:
    /// ChatGPT runs thirteen, Claude runs seven, each a renderer, a GPU
    /// helper, a crash reporter or a network service with its own pid.
    /// Listing them separately filled the view with the same three names
    /// over and over and left nobody able to answer "what is using my
    /// battery", which is a question about an app.
    struct Reading: Identifiable, Sendable, Equatable {
        public let identity: RunningProcessIdentity
        /// How many processes were rolled up here.
        public let processCount: Int
        public let cpuNanoseconds: UInt64
        public let wakeups: UInt64
        public let bytesMoved: UInt64
        /// Energy used across the gap between the two samples, in
        /// nanojoules. Real, from `ri_energy_nj`, rather than the
        /// synthetic score this used to carry: that number had no unit,
        /// so it could be compared against itself and against nothing
        /// else, and could never become a share of a battery.
        public let nanojoules: UInt64

        public var name: String {
            identity.displayName
        }

        public var bundlePath: String? {
            identity.bundlePath
        }

        public var executablePath: String {
            identity.executablePath
        }

        public var milliwattHours: Double {
            Double(nanojoules) / 1_000_000_000 / 3.6
        }

        /// What it is costing right now, in milliwatts, which is the rate
        /// rather than the amount. Shown as the arithmetic it is: this
        /// much energy over this long.
        public func milliwatts(over window: TimeInterval) -> Double {
            guard window > 0 else { return 0 }
            return milliwattHours * 3600 / window
        }

        /// Namespaced, because this list sits in the same `List` as the
        /// totals and their keys are the same paths. Two `ForEach`es whose
        /// ids collide across sections make SwiftUI treat the rows as one
        /// element: three rows of this list rendered as totals rows, with
        /// the totals' numbers, and the bug looked like duplicated data
        /// rather than like conflated identity. The same defect had already
        /// been fixed twice elsewhere in this product.
        public var id: String {
            "now:" + identity.groupKey
        }

        /// What the process actually did, which is what makes a figure
        /// checkable rather than a score to be taken on trust.
        public var processorSeconds: Double {
            Double(cpuNanoseconds) / 1_000_000_000
        }

        /// The one thing most responsible for this row's cost.
        ///
        /// Not a weighted score. Activity Monitor's Energy Impact combines
        /// these with coefficients out of `/usr/share/pmenergy`, and the
        /// best public analysis of it concludes it over-weights wakeups
        /// enough to invert the ranking against real power. Brim already
        /// has real joules, so it does not need a proxy; what it needs is
        /// to say which behaviour the joules came from.
        public func dominantCost(over window: TimeInterval) -> EnergyCost {
            // A wakeup costs roughly 200 microseconds of equivalent work,
            // which is the coefficient Apple's own tables use. Comparing on
            // that footing is the only honest way to rank the two.
            let wakeupEquivalent = Double(wakeups) * 0.0002

            // "Often" has to mean often. Ranking the two costs against each
            // other and stopping there labelled a row with five wakeups in
            // two seconds as "waking up often", because five wakeups still
            // outweighed a processor time of nearly zero. Every row in the
            // list said the same thing, which is the same as saying nothing.
            let perSecond = window > 0 ? Double(wakeups) / window : 0
            let wakesOften = perSecond >= 20

            if processorSeconds >= wakeupEquivalent, processorSeconds > 0.005 {
                return .processor
            }
            if wakesOften {
                return .wakeups
            }
            if processorSeconds > 0.001 {
                return .processor
            }
            if bytesMoved > 0 {
                return .disk
            }
            return .unclear
        }
    }
}

/// The one thing most responsible for a reading's cost, said as the
/// behaviour rather than the counter.
public enum EnergyCost: String, Sendable, Equatable {
    case processor, wakeups, disk, unclear

    /// Said as the behaviour, not the counter.
    public var sentence: String {
        switch self {
        case .processor: "Working steadily"
        case .wakeups: "Waking up often"
        case .disk: "Reading and writing"
        case .unclear: "Mixed activity"
        }
    }
}
