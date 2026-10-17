import BrimCore
import Foundation

public extension EnergyModel {
    /// One application, measured across the gap between two samples. An app,
    /// not a process: a modern app runs many processes, and the question is
    /// which app is using the battery.
    struct Reading: Identifiable, Sendable, Equatable {
        public let identity: RunningProcessIdentity
        /// How many processes were rolled up here.
        public let processCount: Int
        public let cpuNanoseconds: UInt64
        public let wakeups: UInt64
        public let bytesMoved: UInt64
        /// Energy used between the two samples, in nanojoules, from `ri_energy_nj`.
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

        /// What it costs right now, in milliwatts: this much energy over this long.
        public func milliwatts(over window: TimeInterval) -> Double {
            guard window > 0 else { return 0 }
            return milliwattHours * 3600 / window
        }

        /// Namespaced, because this list shares a `List` with the totals and their
        /// keys are the same paths; colliding ids across sections make SwiftUI
        /// treat rows as one.
        public var id: String {
            "now:" + identity.groupKey
        }

        /// What the process did, so a figure can be checked rather than trusted.
        public var processorSeconds: Double {
            Double(cpuNanoseconds) / 1_000_000_000
        }

        /// The behaviour most responsible for this row's cost. Not a weighted
        /// score: Brim has real joules, so it only needs to say where they came
        /// from.
        public func dominantCost(over window: TimeInterval) -> EnergyCost {
            // A wakeup costs roughly 200 microseconds of equivalent work, the
            // coefficient Apple's own tables use.
            let wakeupEquivalent = Double(wakeups) * 0.0002

            // "Often" has to mean often, or every row would say it.
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
