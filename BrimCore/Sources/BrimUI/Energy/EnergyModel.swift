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
        public let name: String
        public let bundlePath: String?
        /// One executable from the group, for the rows with no bundle.
        public let executablePath: String
        /// How many processes were rolled up here.
        public let processCount: Int
        public let cpuNanoseconds: UInt64
        public let wakeups: UInt64
        public let bytesMoved: UInt64
        public let impact: UInt64

        public var id: String { bundlePath ?? executablePath }
    }

    @Published public private(set) var readings: [Reading] = []
    @Published public private(set) var isSampling = false
    @Published public private(set) var coverageGaps = 0
    @Published public private(set) var window: TimeInterval = 0

    /// How long to leave between the two samples. Long enough for a busy
    /// process to separate itself from an idle one, short enough that
    /// nobody minds waiting.
    private let gap: Duration = .seconds(2)

    public init() {}

    public var measured: Int { readings.count }

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

        readings = Self.group(second.samples.compactMap { now -> Measured? in
            // A process that appeared between samples has no baseline, so
            // its total would be mistaken for its rate. Left out rather
            // than guessed at.
            guard let then = before[now.pid] else { return nil }

            let cpu = now.userTime &+ now.systemTime &- (then.userTime &+ then.systemTime)
            let wakeups = now.wakeups >= then.wakeups ? now.wakeups - then.wakeups : 0
            let io = (now.diskReadBytes &+ now.diskWriteBytes)
                &- (then.diskReadBytes &+ then.diskWriteBytes)
            let impact = now.impactScore >= then.impactScore
                ? now.impactScore - then.impactScore : 0
            guard impact > 0 else { return nil }

            return Measured(
                bundlePath: now.bundlePath,
                executablePath: now.executablePath,
                cpuNanoseconds: cpu,
                wakeups: wakeups,
                bytesMoved: io,
                impact: impact
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
        let impact: UInt64
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

        for item in measured {
            let key = item.bundlePath ?? item.executablePath
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }

        return order.compactMap { key -> Reading? in
            guard let group = buckets[key], let first = group.first else { return nil }
            return Reading(
                name: Self.name(bundlePath: first.bundlePath, executablePath: first.executablePath),
                bundlePath: first.bundlePath,
                executablePath: first.executablePath,
                processCount: group.count,
                cpuNanoseconds: group.reduce(0) { $0 &+ $1.cpuNanoseconds },
                wakeups: group.reduce(0) { $0 &+ $1.wakeups },
                bytesMoved: group.reduce(0) { $0 &+ $1.bytesMoved },
                impact: group.reduce(0) { $0 &+ $1.impact }
            )
        }
        .sorted { $0.impact > $1.impact }
    }

    /// The app's name where the process belongs to one, and the executable
    /// name otherwise. A bare executable name is right for a daemon and
    /// wrong for an app somebody recognises by its icon.
    static func name(bundlePath: String?, executablePath: String) -> String {
        if let bundlePath {
            return URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
        }
        return URL(fileURLWithPath: executablePath).lastPathComponent
    }
}
