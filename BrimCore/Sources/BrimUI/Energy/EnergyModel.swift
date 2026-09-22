import Foundation
import Combine
import BrimCore
import BrimProtocol

/// Backs the Energy section.
///
/// Two samples taken a moment apart, and the difference between them is
/// what gets shown. A single reading tells you what a process has used
/// since it launched, which makes anything running since login look
/// enormous and anything started a minute ago look idle. The delta says
/// what is costing you something now, which is the only question worth
/// asking.
///
/// What the panel shows is two different facts and they are kept apart on
/// purpose. **Right now** is a rate, in milliwatts, measured across the gap.
/// **Since counting started** is an amount, in milliwatt-hours, accumulated
/// in the ledger. Printing both as "mWh" in two adjacent lists, which is
/// what it used to do, made three rows look duplicated and left nobody able
/// to say which number meant what.
@MainActor
public final class EnergyModel: ObservableObject {

    /// One application, measured across the gap between two samples.
    ///
    /// An application, not a process. A modern Mac app is a crowd of them:
    /// ChatGPT runs thirteen, Claude runs seven, each a renderer, a GPU
    /// helper, a crash reporter or a network service with its own pid.
    /// Listing them separately filled the view with the same three names
    /// over and over and left nobody able to answer "what is using my
    /// battery", which is a question about an app.
    public struct Reading: Identifiable, Sendable, Equatable {
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

        public var name: String { identity.displayName }
        public var bundlePath: String? { identity.bundlePath }
        public var executablePath: String { identity.executablePath }

        public var milliwattHours: Double { Double(nanojoules) / 1_000_000_000 / 3.6 }

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
        public var id: String { "now:" + identity.groupKey }

        /// What the process actually did, which is what makes a figure
        /// checkable rather than a score to be taken on trust.
        public var processorSeconds: Double { Double(cpuNanoseconds) / 1_000_000_000 }

        /// The one thing most responsible for this row's cost.
        ///
        /// Not a weighted score. Activity Monitor's Energy Impact combines
        /// these with coefficients out of `/usr/share/pmenergy`, and the
        /// best public analysis of it concludes it over-weights wakeups
        /// enough to invert the ranking against real power. Brim already
        /// has real joules, so it does not need a proxy; what it needs is
        /// to say which behaviour the joules came from.
        public func dominantCost(over window: TimeInterval) -> Cost {
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

            if processorSeconds >= wakeupEquivalent && processorSeconds > 0.005 { return .processor }
            if wakesOften { return .wakeups }
            if processorSeconds > 0.001 { return .processor }
            if bytesMoved > 0 { return .disk }
            return .unclear
        }

        public enum Cost: String, Sendable, Equatable {
            case processor, wakeups, disk, unclear

            /// Said as the behaviour, not the counter.
            public var sentence: String {
                switch self {
                case .processor: return "Working steadily"
                case .wakeups: return "Waking up often"
                case .disk: return "Reading and writing"
                case .unclear: return "Mixed activity"
                }
            }
        }
    }

    @Published public private(set) var readings: [Reading] = []
    @Published public private(set) var isSampling = false
    @Published public private(set) var coverageGaps = 0
    @Published public private(set) var window: TimeInterval = 0
    /// Energy per application since counting started, which survives both
    /// the application restarting and Brim restarting.
    @Published public private(set) var totals: EnergyTotals?
    /// This Mac's battery, so energy can be said as a share of a full
    /// charge. Nil on a machine with no battery, where a share of one is
    /// not a thing that can be said.
    public let battery: BatteryCapacity? = BatteryCapacity.current()
    /// What is holding sleep off. The one thing in this panel that neither
    /// System Settings nor Activity Monitor says plainly.
    @Published public private(set) var assertions: PowerAssertions = .notRead

    /// How long to leave between the two samples. Long enough for a busy
    /// process to separate itself from an idle one, short enough that
    /// nobody minds waiting.
    private let gap: Duration = .seconds(2)

    public init() {}

    public var measured: Int { readings.count }

    // MARK: - What the panel is made of

    /// Things the person launched, which is what they can act on.
    public var yours: [Reading] { readings.filter { $0.identity.kind.isActionable } }

    /// macOS running itself. Separated rather than hidden: it is often the
    /// largest share of the reading, and a list that mixes "quit Figma"
    /// with "Spotlight is indexing" invites somebody to try to stop the
    /// second one.
    public var macOS: [Reading] { readings.filter { !$0.identity.kind.isActionable } }

    public var totalMilliwatts: Double {
        readings.reduce(0) { $0 + $1.milliwatts(over: window) }
    }

    public func milliwatts(of readings: [Reading]) -> Double {
        readings.reduce(0) { $0 + $1.milliwatts(over: window) }
    }

    /// The single busiest thing, for the card at the top.
    public var busiest: Reading? { readings.first }

    /// The reading as facts, for the deterministic sentence today and for
    /// the model to narrate under T-7.6.
    public var insight: EnergyInsight {
        EnergyInsight(
            windowSeconds: window,
            totalMilliwatts: totalMilliwatts,
            yoursMilliwatts: milliwatts(of: yours),
            systemMilliwatts: milliwatts(of: macOS),
            busiestName: busiest?.name,
            busiestMilliwatts: busiest.map { $0.milliwatts(over: window) } ?? 0,
            busiestIsSystem: busiest.map { !$0.identity.kind.isActionable } ?? false,
            busiestBehaviour: busiest.map { $0.dominantCost(over: window).sentence },
            busiestIsBrimItself: busiest?.identity.bundlePath.map {
                $0 == Bundle.main.bundleURL.path
            } ?? false,
            unreadableProcesses: coverageGaps,
            batteryMilliwattHours: battery?.designMilliwattHours
        )
    }

    // MARK: - Totals

    /// Totals, classified the same way the live readings are, so the two
    /// halves of the panel agree about what a thing is.
    public struct Total: Identifiable, Sendable, Equatable {
        public let identity: RunningProcessIdentity
        public let milliwattHours: Double
        /// Namespaced away from the live list. See `Reading.id`.
        public var id: String { "total:" + identity.groupKey }
        public var name: String { identity.displayName }
    }

    public var accumulated: [Total] {
        guard let totals else { return [] }
        return totals.accumulated.map { entry in
            Total(
                identity: RunningProcessIdentity.of(
                    bundlePath: entry.isApplication ? entry.key : nil,
                    executablePath: entry.key
                ),
                milliwattHours: entry.milliwattHours
            )
        }
        .sorted { $0.milliwattHours > $1.milliwattHours }
    }

    public var accumulatedTotalMilliwattHours: Double {
        accumulated.reduce(0) { $0 + $1.milliwattHours }
    }

    /// Everything measured since counting started, as a share of a full
    /// charge.
    ///
    /// The number people can hold on to. A column of four-digit milliwatt
    /// hours, 2428 against 1926 against 1473, is arithmetic nobody asked
    /// for: it has no anchor, no familiar unit, and the differences between
    /// the rows are the only information in it. A share of a charge answers
    /// the question the panel is for.
    public var accumulatedShareOfACharge: Double? {
        guard let battery, battery.designMilliwattHours > 0 else { return nil }
        return accumulatedTotalMilliwattHours / battery.designMilliwattHours
    }

    /// One total as a share of everything measured, which is what the bar
    /// beside it draws.
    public func share(of total: Total) -> Double {
        let sum = accumulatedTotalMilliwattHours
        return sum > 0 ? total.milliwattHours / sum : 0
    }

    // MARK: - Sampling

    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        guard readings.isEmpty, !isSampling else { return }
        await sample(service: service)
    }

    public func sample(service: any BrimServiceProtocol) async {
        isSampling = true
        defer { isSampling = false }

        let started = Date()
        let first = await service.sampleEnergy()
        try? await Task.sleep(for: gap)
        let second = await service.sampleEnergy()
        window = Date().timeIntervalSince(started)

        let before = Dictionary(first.samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        coverageGaps = second.coverageGaps
        totals = await service.energyTotals()
        assertions = PowerAssertions.current()

        readings = Self.group(second.samples.compactMap { now -> Measured? in
            // A process that appeared between samples has no baseline, so
            // its total would be mistaken for its rate. Left out rather
            // than guessed at.
            guard let then = before[now.pid] else { return nil }

            let cpu = now.userTime &+ now.systemTime &- (then.userTime &+ then.systemTime)
            let wakeups = now.wakeups >= then.wakeups ? now.wakeups - then.wakeups : 0
            let io = (now.diskReadBytes &+ now.diskWriteBytes)
                &- (then.diskReadBytes &+ then.diskWriteBytes)
            let nanojoules = now.energyNanojoules >= then.energyNanojoules
                ? now.energyNanojoules - then.energyNanojoules : 0
            // Below a hundredth of a milliwatt-hour across the window is
            // measurement noise. Seventy-seven rows all reading 0.02 mWh
            // is a list nobody can act on.
            guard nanojoules >= 36_000_000 else { return nil }

            return Measured(
                bundlePath: now.bundlePath,
                executablePath: now.executablePath,
                cpuNanoseconds: cpu,
                wakeups: wakeups,
                bytesMoved: io,
                nanojoules: nanojoules
            )
        })
    }

    /// One process, before the processes belonging to the same application
    /// are added together.
    struct Measured: Sendable {
        let bundlePath: String?
        let executablePath: String
        let cpuNanoseconds: UInt64
        let wakeups: UInt64
        let bytesMoved: UInt64
        let nanojoules: UInt64
    }

    /// Adds up the processes belonging to one application.
    ///
    /// Keyed on the bundle when there is one, and the executable otherwise,
    /// so a daemon running several copies of itself also collapses to a
    /// single line. `EnergySampler` already walks out to the outermost
    /// bundle, so a renderer nested three frameworks deep inside ChatGPT
    /// arrives here pointing at `/Applications/ChatGPT.app`.
    static func group(_ measured: [Measured]) -> [Reading] {
        var order: [String] = []
        var buckets: [String: [Measured]] = [:]
        var identities: [String: RunningProcessIdentity] = [:]

        for item in measured {
            let identity = RunningProcessIdentity.of(
                bundlePath: item.bundlePath, executablePath: item.executablePath
            )
            let key = identity.groupKey
            if buckets[key] == nil {
                order.append(key)
                identities[key] = identity
            }
            buckets[key, default: []].append(item)
        }

        return order.compactMap { key -> Reading? in
            guard let group = buckets[key], let identity = identities[key] else { return nil }
            return Reading(
                identity: identity,
                processCount: group.count,
                cpuNanoseconds: group.reduce(0) { $0 &+ $1.cpuNanoseconds },
                wakeups: group.reduce(0) { $0 &+ $1.wakeups },
                bytesMoved: group.reduce(0) { $0 &+ $1.bytesMoved },
                nanojoules: group.reduce(0) { $0 &+ $1.nanojoules }
            )
        }
        .sorted { $0.nanojoules > $1.nanojoules }
    }
}
