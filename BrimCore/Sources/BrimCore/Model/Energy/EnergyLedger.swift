import Foundation

/// Energy accumulated per application, across restarts of everything.
///
/// `ri_energy_nj` is a counter a process keeps since *it* started. Quit
/// the application and it is gone; quit Brim and the reading is gone too.
/// So a single sample can only ever answer "what has this process spent
/// since it launched", which is not the question anybody has. The
/// question is what a piece of software costs to keep around.
///
/// The answer is deltas. Each sample is compared against the last reading
/// for the same process, the difference is added to that application's
/// running total, and the total is written down. A process that restarts
/// starts from zero and its first delta is its whole new reading, which
/// is correct. Brim restarting changes nothing, because the totals are on
/// disk and the per-process readings with them.
///
/// Identity is the pid *and* the start time. Pids are reused within an
/// uptime, and without the start time a new process inherits whatever the
/// last holder of its pid had spent, then reports a huge negative delta
/// that gets clamped to zero and loses the real usage.
public struct EnergyLedger: Codable, Equatable, Sendable {

    /// What one process had spent when Brim last looked.
    public struct Reading: Codable, Equatable, Sendable {
        public let pid: Int32
        public let startedAt: UInt64
        public let nanojoules: UInt64

        public init(pid: Int32, startedAt: UInt64, nanojoules: UInt64) {
            self.pid = pid
            self.startedAt = startedAt
            self.nanojoules = nanojoules
        }

        /// Whether this reading and that sample are the same run of the
        /// same process.
        func isSameProcess(as sample: EnergySample) -> Bool {
            pid == sample.pid && startedAt == sample.startedAt
        }
    }

    /// Accumulated nanojoules, keyed by bundle path where there is one
    /// and by executable path otherwise.
    ///
    /// Keying by bundle is the coalition: a browser's dozen renderer
    /// processes and its GPU process all roll into the application, which
    /// is the only level anybody can act on. Nothing can be done about
    /// "Claude Helper (Renderer)" except close Claude.
    public private(set) var totals: [String: UInt64]
    /// The last reading for each live process.
    public private(set) var readings: [Reading]
    public private(set) var since: Date

    public init(
        totals: [String: UInt64] = [:],
        readings: [Reading] = [],
        since: Date = Date()
    ) {
        self.totals = totals
        self.readings = readings
        self.since = since
    }

    /// Folds a fresh sample in and returns the ledger that results.
    ///
    /// Pure, so the arithmetic can be tested without a machine and
    /// without waiting for anything to burn energy.
    public func accumulating(_ result: EnergySampleResult) -> EnergyLedger {
        var newTotals = totals
        var newReadings: [Reading] = []

        var previous: [Int64: Reading] = [:]
        for reading in readings {
            previous[Self.key(pid: reading.pid, startedAt: reading.startedAt)] = reading
        }

        for sample in result.samples {
            let key = sample.bundlePath ?? sample.executablePath
            let identity = Self.key(pid: sample.pid, startedAt: sample.startedAt)

            let delta: UInt64
            if let before = previous[identity], before.isSameProcess(as: sample) {
                // A counter that went backwards is not possible for the
                // same run of the same process; if it happens the reading
                // is untrustworthy and contributing nothing beats
                // contributing a wrong number.
                delta = sample.energyNanojoules >= before.nanojoules
                    ? sample.energyNanojoules - before.nanojoules
                    : 0
            } else {
                // First time this process has been seen. Its counter is
                // what it has spent since it started, all of which is
                // energy this application used.
                delta = sample.energyNanojoules
            }

            newTotals[key, default: 0] += delta
            newReadings.append(Reading(
                pid: sample.pid, startedAt: sample.startedAt,
                nanojoules: sample.energyNanojoules
            ))
        }

        return EnergyLedger(totals: newTotals, readings: newReadings, since: since)
    }

    /// What one application has spent, in milliwatt-hours.
    public func milliwattHours(for key: String) -> Double {
        Double(totals[key] ?? 0) / 1_000_000_000 / 3.6
    }

    /// Everything accumulated, heaviest first.
    public func ranked() -> [(key: String, milliwattHours: Double)] {
        totals
            .map { (key: $0.key, milliwattHours: Double($0.value) / 1_000_000_000 / 3.6) }
            .sorted { $0.milliwattHours > $1.milliwattHours }
    }

    private static func key(pid: Int32, startedAt: UInt64) -> Int64 {
        Int64(pid) &* 31 &+ Int64(bitPattern: startedAt)
    }
}

/// Where the ledger lives between runs.
public struct EnergyLedgerStore: Sendable {
    private let url: URL

    public init(directoryURL: URL) {
        self.url = directoryURL.appendingPathComponent("energy.json")
    }

    public func load() -> EnergyLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(EnergyLedger.self, from: data)
        else { return EnergyLedger() }
        return ledger
    }

    public func save(_ ledger: EnergyLedger) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(ledger).write(to: url, options: .atomic)
    }
}
