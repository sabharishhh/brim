import BrimCore
import BrimProtocol
import Combine
import Foundation

/// Backs the Energy section. Two samples a moment apart, and the difference
/// shown: a single reading is what a process used since launch, which makes
/// long-running ones look enormous. Applications only: listing the services
/// beneath them offers suspects nobody can act on.
@MainActor
public final class EnergyModel: ObservableObject {
    @Published public private(set) var readings: [Reading] = []
    @Published public private(set) var isSampling = false
    @Published public private(set) var coverageGaps = 0
    @Published public private(set) var window: TimeInterval = 0
    /// What is holding sleep off.
    @Published public private(set) var assertions: PowerAssertions = .notRead

    /// The time between samples: long enough to separate busy from idle, short
    /// enough that nobody minds waiting.
    private let gap: Duration
    /// How often a live reading samples again.
    private let tick: Duration

    public init(gap: Duration = .seconds(2), tick: Duration = .seconds(3)) {
        self.gap = gap
        self.tick = tick
    }

    public var measured: Int {
        readings.count
    }

    // MARK: - What the panel is made of

    /// Applications, and nothing else. Services such as `powerd` or `coreaudiod`
    /// are busy because of an app, and listing them beside it offers suspects
    /// nobody can act on. An app Apple ships is still an app: the line is
    /// whether there is a window to quit.
    public var applications: [Reading] {
        readings.filter { $0.identity.kind.isActionable && $0.bundlePath != Self.ownBundle }
    }

    /// Brim itself, busy because it is taking the reading.
    private static let ownBundle = Bundle.main.bundleURL.standardizedFileURL.path

    public func milliwatts(of readings: [Reading]) -> Double {
        readings.reduce(0) { $0 + $1.milliwatts(over: window) }
    }

    /// One app's part of what every listed app drew, for the bar beside it.
    /// Against the total rather than the busiest, so the bars add up to the
    /// whole and a quiet Mac looks quiet.
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

    /// Sleep, charge and stay-awake requests from power management's log, read
    /// beside a reading rather than before it, because it takes a few seconds.
    @Published public private(set) var history: PowerHistory?
    @Published public private(set) var awakeRequests: [AwakeRequest] = []
    @Published public private(set) var isReadingHistory = false
    private var historyTask: Task<Void, Never>?
    private var historyReadAt: Date?

    /// Read at most once an hour: slow to read, slow to change.
    private func readHistory() {
        guard historyTask == nil,
              historyReadAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true else { return }
        historyReadAt = Date()
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

    /// Only what an application holds. macOS's own assertions follow from
    /// those.
    public var appsKeepingMacAwake: [PowerAssertions.Held] {
        assertions.held.filter(\.isYours)
    }

    // MARK: - Why there is no running total

    // MARK: - Sampling

    /// The battery, temperature and Low Power Mode, kept current while the
    /// calling task runs: read once, then again whenever macOS reports a change.
    public func followCondition() async {
        readHistory()
        await readCondition()
        for await _ in PowerEvents.changes() {
            await readCondition()
        }
    }

    private func readCondition() async {
        condition = SystemCondition.current()
        battery = await Task.detached(priority: .utility) { BatteryReport.current() }.value
        hasReadBattery = true
    }

    /// How far back a live reading looks: long enough that rows do not jump,
    /// short enough to follow what someone just did.
    static let span: TimeInterval = 15

    /// Which apps are drawing power, while the Energy page is on screen and
    /// Brim can be seen. The first figure arrives after two seconds; then a
    /// sample every three seconds (nine in Low Power Mode), each under a
    /// millisecond, measured across the last fifteen. Nothing is sampled while
    /// hidden, and a window that was hidden starts from a fresh baseline.
    public func follow(
        service: any BrimServiceProtocol, visible: @escaping @MainActor () -> Bool = { AppVisibility.isVisible }
    ) async {
        readHistory()
        var samples: [(at: Date, result: EnergySampleResult)] = []
        isSampling = readings.isEmpty
        defer { isSampling = false }
        while !Task.isCancelled {
            guard visible() else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            if let last = samples.last, Date().timeIntervalSince(last.at) > Self.span {
                samples = []
            }
            await samples.append((Date(), service.sampleEnergy()))
            if samples.count == 1 {
                try? await Task.sleep(for: gap)
                continue
            }
            // The oldest sample kept is the newest one at least a span old.
            let cutoff = Date().addingTimeInterval(-Self.span)
            while samples.count > 2, samples[1].at <= cutoff {
                samples.removeFirst()
            }
            if let first = samples.first, let last = samples.last {
                await publish(from: first.result, to: last.result, over: last.at.timeIntervalSince(first.at))
            }
            isSampling = false
            try? await Task.sleep(for: condition.lowPowerMode ? tick * 3 : tick)
        }
    }

    /// One reading over two seconds, for Check Again.
    public func sample(service: any BrimServiceProtocol) async {
        readHistory()
        isSampling = true
        defer { isSampling = false }

        let started = Date()
        let first = await service.sampleEnergy()
        try? await Task.sleep(for: gap)
        let second = await service.sampleEnergy()
        await publish(from: first, to: second, over: Date().timeIntervalSince(started))
    }

    /// What each app drew between two samples.
    private func publish(from first: EnergySampleResult, to second: EnergySampleResult, over span: TimeInterval) async {
        window = span
        let before = Dictionary(first.samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        coverageGaps = second.coverageGaps
        assertions = PowerAssertions.current()
        await readCondition()

        readings = Self.group(second.samples.compactMap { now -> Measured? in
            // A process that appeared between samples has no baseline, so its total
            // would read as a rate. Left out.
            guard let then = before[now.pid] else { return nil }

            let cpu = now.userTime &+ now.systemTime &- (then.userTime &+ then.systemTime)
            let wakeups = now.wakeups >= then.wakeups ? now.wakeups - then.wakeups : 0
            let io = (now.diskReadBytes &+ now.diskWriteBytes)
                &- (then.diskReadBytes &+ then.diskWriteBytes)
            let nanojoules = now.energyNanojoules >= then.energyNanojoules
                ? now.energyNanojoules - then.energyNanojoules : 0
            // Below a hundredth of a milliwatt-hour across the window is noise.
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

    /// Adds up the processes of one application, keyed on the bundle (or the
    /// executable), so several copies of a daemon also make one line.
    /// `EnergySampler` already walks out to the outermost bundle.
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
