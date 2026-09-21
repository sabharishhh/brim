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

    /// One process, measured across the gap between two samples.
    public struct Reading: Identifiable, Sendable, Equatable {
        public let pid: Int32
        public let name: String
        public let bundlePath: String?
        public let executablePath: String
        public let cpuNanoseconds: UInt64
        public let wakeups: UInt64
        public let bytesMoved: UInt64
        public let impact: UInt64

        public var id: Int32 { pid }
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

        readings = second.samples.compactMap { now -> Reading? in
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

            return Reading(
                pid: now.pid,
                name: Self.name(for: now),
                bundlePath: now.bundlePath,
                executablePath: now.executablePath,
                cpuNanoseconds: cpu,
                wakeups: wakeups,
                bytesMoved: io,
                impact: impact
            )
        }
        .sorted { $0.impact > $1.impact }
    }

    /// The app's name where the process belongs to one, and the executable
    /// name otherwise. A bare executable name is right for a daemon and
    /// wrong for an app the user recognises by its bundle.
    static func name(for sample: EnergySample) -> String {
        if let bundlePath = sample.bundlePath {
            return URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
        }
        return URL(fileURLWithPath: sample.executablePath).lastPathComponent
    }
}
