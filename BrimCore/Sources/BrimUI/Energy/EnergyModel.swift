import BrimCore
import BrimProtocol
import Combine
import Foundation

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

    public var measured: Int {
        readings.count
    }

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
        readings.filter { $0.identity.kind.isActionable && $0.bundlePath != Self.ownBundle }
    }

    /// Brim itself, which is busy precisely because it is taking the
    /// reading. Listed, it was often the only app, "waking up often", at
    /// the top of a list meant to show what else is costing power.
    private static let ownBundle = Bundle.main.bundleURL.standardizedFileURL.path

    public func milliwatts(of readings: [Reading]) -> Double {
        readings.reduce(0) { $0 + $1.milliwatts(over: window) }
    }

    /// The busiest application, which is the one the panel leads with.
    public var busiest: Reading? {
        applications.first
    }

    /// One application's part of what every listed application drew, for
    /// the bar beside it.
    ///
    /// It used to be measured against the busiest, so the first row was
    /// always a full bar: on a Mac at rest, an app drawing a third of a
    /// watt filled its row as though it were the problem. Against the total,
    /// the bars add up to the whole and a quiet Mac looks quiet.
    public func share(of reading: Reading) -> Double {
        share(of: reading.nanojoules)
    }

    public func share(of nanojoules: UInt64) -> Double {
        let total = applications.reduce(UInt64(0)) { $0 &+ $1.nanojoules }
        return total > 0 ? Double(nanojoules) / Double(total) : 0
    }

    /// How many rows are shown before the rest fold into one.
    public static let shownApplications = 6

    /// The rows the panel lists, busiest first.
    public var shownApplications: [Reading] {
        Array(applications.prefix(Self.shownApplications))
    }

    /// Everything past the shown rows, as one figure.
    public var others: (count: Int, nanojoules: UInt64)? {
        let rest = applications.dropFirst(Self.shownApplications)
        guard !rest.isEmpty else { return nil }
        return (rest.count, rest.reduce(UInt64(0)) { $0 &+ $1.nanojoules })
    }

    /// Milliwatts for a number of nanojoules over this reading's window.
    public func milliwatts(nanojoules: UInt64) -> Double {
        guard window > 0 else { return 0 }
        return Double(nanojoules) / 1_000_000 / window
    }

    /// The battery and the whole Mac's draw. Nil on a Mac with no battery.
    @Published public private(set) var battery: BatteryReport?
    /// Whether the battery has been read, so nil means "no battery" and
    /// not "not looked yet".
    @Published public private(set) var hasReadBattery = false

    // MARK: - The last few days

    /// One application and how long it asked the Mac to stay awake.
    public struct AwakeRequest: Identifiable, Sendable, Equatable {
        public let name: String
        public let bundlePath: String
        public let seconds: TimeInterval
        public var id: String {
            bundlePath
        }
    }

    /// Sleep, charge and stay-awake requests from power management's own
    /// log. Read when the page asks for a reading, beside it rather than
    /// before it, because reading the log takes a few seconds.
    @Published public private(set) var history: PowerHistory?
    @Published public private(set) var awakeRequests: [AwakeRequest] = []
    @Published public private(set) var isReadingHistory = false
    private var historyTask: Task<Void, Never>?

    private func readHistory() {
        guard historyTask == nil else { return }
        isReadingHistory = true
        historyTask = Task {
            let (history, names) = await Task.detached(priority: .utility) {
                (PowerHistory.current(), ApplicationNames.installed())
            }.value
            self.history = history
            awakeRequests = history?.requestsByApplication(names).map {
                AwakeRequest(name: $0.app.name, bundlePath: $0.app.bundlePath, seconds: $0.seconds)
            } ?? []
            isReadingHistory = false
            historyTask = nil
        }
    }

    /// How the Mac is coping, from Apple's public interfaces.
    @Published public private(set) var condition: SystemCondition =
        .init(thermal: .normal, power: nil, lowPowerMode: false)

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

    /// What Home shows: the battery, and the power log read beside it.
    /// No sampling, which is the Energy page's to ask for.
    public func loadOverview() async {
        readHistory()
        // Cheap and changes by the minute, so read on every visit.
        condition = SystemCondition.current()
        guard !hasReadBattery else { return }
        battery = await Task.detached(priority: .utility) { BatteryReport.current() }.value
        hasReadBattery = true
    }

    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        guard readings.isEmpty, !isSampling else { return }
        await sample(service: service)
    }

    public func sample(service: any BrimServiceProtocol) async {
        readHistory()
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
        battery = await Task.detached(priority: .userInitiated) { BatteryReport.current() }.value
        hasReadBattery = true

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
