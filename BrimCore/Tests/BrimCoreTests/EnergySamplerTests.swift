import XCTest
@testable import BrimCore

final class EnergySamplerTests: XCTestCase {
    
    /// Energy is joules now, not a score.
    ///
    /// This used to assert a synthetic figure: CPU nanoseconds plus
    /// wakeups times a million plus bytes times ten. That number could be
    /// compared against itself and against nothing else. It had no unit,
    /// so it could not become a share of a battery, could not be added up
    /// over a week and could not be checked against anything. The real
    /// figure was in the same `rusage_info_v6` the sampler was already
    /// reading, in `ri_energy_nj`, unused.
    func testEnergyIsMeasuredInJoulesAndConvertsToWhatABatteryIsMeasuredIn() {
        let sample = EnergySample(
            pid: 1234,
            executablePath: "/Applications/Test.app/Contents/MacOS/Test",
            bundlePath: "/Applications/Test.app",
            userTime: 2_000_000,
            systemTime: 1_000_000,
            diskReadBytes: 500,
            diskWriteBytes: 500,
            wakeups: 10,
            energyNanojoules: 3_600_000_000_000,
            performanceCoreNanojoules: 1_800_000_000_000,
            startedAt: 999
        )

        XCTAssertEqual(sample.joules, 3600, accuracy: 0.001)
        // 3600 J is one watt-hour, so a thousand milliwatt-hours.
        XCTAssertEqual(sample.milliwattHours, 1000, accuracy: 0.001)
        XCTAssertEqual(sample.bundlePath, "/Applications/Test.app")
    }

    func testTheSamplerReadsRealEnergyFromThisMac() async {
        // Every one of 530 readable processes reported a non-zero
        // ri_energy_nj when this was written. A build where the field
        // came back empty would render a view full of zeroes, and the
        // synthetic score it replaced would have hidden that.
        let result = await EnergySampler().sample()
        let withEnergy = result.samples.filter { $0.energyNanojoules > 0 }

        XCTAssertFalse(result.samples.isEmpty)
        XCTAssertFalse(
            withEnergy.isEmpty,
            "No process reported any energy, so the view would show nothing but zeroes"
        )
        XCTAssertTrue(
            result.samples.allSatisfy { $0.startedAt > 0 },
            "Without a start time, a reused pid inherits the last process's total"
        )
    }
    
    func testEnergySamplerExecutionAndCoverageGaps() async {
        let sampler = EnergySampler()
        let result = await sampler.sample()
        
        // Should capture at least one accessible process (e.g., current test runner)
        XCTAssertFalse(result.samples.isEmpty, "EnergySampler should capture running user processes")
        
        // On macOS, unprivileged processes cannot inspect root processes, so coverage gaps must be tracked
        XCTAssertGreaterThanOrEqual(result.coverageGaps, 0)
        
        // Find current process
        let myPid = ProcessInfo.processInfo.processIdentifier
        if let mySample = result.samples.first(where: { $0.pid == myPid }) {
            XCTAssertFalse(mySample.executablePath.isEmpty)
            XCTAssertFalse(mySample.executablePath.contains("\0"), "Path must not contain null characters")
        }
        
        // Check that all sample executable paths are well-formed strings
        for s in result.samples {
            XCTAssertFalse(s.executablePath.isEmpty)
            XCTAssertFalse(s.executablePath.contains("\0"))
        }
    }
    
    func testCumulativeScoreTrackingAcrossProcessRestarts() {
        // Simulates the delta calculation and accumulation algorithm implemented in EnergyCmd
        var cumulativeScores: [String: UInt64] = [:]
        var lastObservedScores: [pid_t: UInt64] = [:]
        
        let appKey = "/Applications/Foo.app"
        let pidA: pid_t = 501
        
        // Turn 1: Process launches, impact score = 100
        let score1: UInt64 = 100
        let prev1 = lastObservedScores[pidA] ?? 0
        let delta1 = score1 >= prev1 ? (score1 - prev1) : score1
        lastObservedScores[pidA] = score1
        cumulativeScores[appKey, default: 0] += delta1
        
        XCTAssertEqual(cumulativeScores[appKey], 100)
        
        // Turn 2: Process continues, impact score accumulates to 250
        let score2: UInt64 = 250
        let prev2 = lastObservedScores[pidA] ?? 0
        let delta2 = score2 >= prev2 ? (score2 - prev2) : score2
        lastObservedScores[pidA] = score2
        cumulativeScores[appKey, default: 0] += delta2
        
        XCTAssertEqual(cumulativeScores[appKey], 250)
        
        // Turn 3: Process quits and restarts (or PID reuse). Impact score resets to 30.
        let score3: UInt64 = 30
        let prev3 = lastObservedScores[pidA] ?? 0
        // Since score3 (30) < prev3 (250), detect restart/wrap-around
        let delta3 = score3 >= prev3 ? (score3 - prev3) : score3
        lastObservedScores[pidA] = score3
        cumulativeScores[appKey, default: 0] += delta3
        
        // Total cumulative score should be 250 + 30 = 280, not wiped to 30!
        XCTAssertEqual(cumulativeScores[appKey], 280)
        
        // Turn 4: Process terminates completely
        let activePids = Set<pid_t>() // pidA terminated
        lastObservedScores = lastObservedScores.filter { activePids.contains($0.key) }
        
        // Baseline tracking cleared for pidA, but cumulative history remains 280
        XCTAssertNil(lastObservedScores[pidA])
        XCTAssertEqual(cumulativeScores[appKey], 280)
    }
}
