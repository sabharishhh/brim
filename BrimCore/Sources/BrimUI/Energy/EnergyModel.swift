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
/// It reports applications and nothing else. A list that also named the
/// services underneath them offered four suspects for one event, three of
/// which nobody can act on, and put `powerd` under "keeping this Mac awake"
/// for doing its job correctly.
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

    /// Applications, and nothing else.
    ///
    /// The panel used to carry a second list of macOS services beside this
    /// one. It was accurate and it was a mistake. `powerd` appeared under
    /// "Keeping this Mac awake" holding an assertion named "Prevent sleep
    /// while display is on", which is macOS working correctly: the display
    /// is on because somebody is using the Mac, and it goes when they stop.
    /// Read by someone who does not already know that, it says an internal
    /// process is stopping their Mac from ever sleeping, which is alarming
    /// and false.
    ///
    /// The same is true of the whole services list. `coreaudiod` is busy
    /// because Music is playing; `WindowServer` is busy because there are
    /// pixels. Naming them beside the app that caused them offers a person
    /// four suspects for one event, three of which they cannot act on and
    /// none of which they can tell apart.
    ///
    /// An application Apple ships is still an application: Music, Safari and
    /// Mail are things a person opened and can close. The line is not who
    /// wrote it, it is whether there is a window to quit.
    public var applications: [Reading] {
        readings.filter { $0.identity.kind.isActionable }
    }

    public func milliwatts(of readings: [Reading]) -> Double {
        readings.reduce(0) { $0 + $1.milliwatts(over: window) }
    }

    /// The busiest application, which is the one the panel leads with.
    public var busiest: Reading? { applications.first }

    /// One application against the busiest, for the bar beside it.
    public func share(of reading: Reading) -> Double {
        let top = applications.first?.nanojoules ?? 0
        return top > 0 ? Double(reading.nanojoules) / Double(top) : 0
    }

    /// How the Mac is coping, from Apple's public interfaces.
    @Published public private(set) var condition: SystemCondition =
        SystemCondition(thermal: .normal, power: nil, lowPowerMode: false)

    /// Only what an application is holding. macOS holds its own whenever the
    /// screen is on or audio is routed, and those follow from whatever asked
    /// for them rather than causing anything.
    public var appsKeepingMacAwake: [PowerAssertions.Held] {
        assertions.held.filter(\.isYours)
    }


    // MARK: - Why there is no running total

    // There was a "Since <date>" card here and it has gone, because it was
    // measuring something other than what it said.
    //
    // A running total would credit a process's entire counter the
    // first time it sees that process: "First time this process has been
    // seen. Its counter is what it has spent since it started, all of which
    // is energy this application used." For a daemon running since boot that
    // is days of energy, filed under a heading that named the moment Brim
    // first looked. `contactsd` read 2428 mWh on this Mac against a label
    // saying "Since Sep 21, 2026 at 8:23 PM".
    //
    // The honest version would need Brim to have been watching the whole
    // time, and Brim does not watch. It has no agent, no timer and no
    // background job, on purpose: a utility that exists to find software
    // running when nobody asked it to cannot leave something running when
    // nobody asked it to. A reading is taken when a person presses the
    // button, and it describes the seconds it was taken over.

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
        assertions = PowerAssertions.current()
        condition = SystemCondition.current()

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
