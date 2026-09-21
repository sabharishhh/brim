import XCTest
@testable import BrimCore

/// Energy that survives the process it was measured on.
///
/// `ri_energy_nj` is a counter a process keeps since it started. Quit the
/// application and it is gone; quit Brim and the reading is gone too. So
/// a single sample can only answer "what has this process spent since it
/// launched", which is not a question anybody has. The question is what a
/// piece of software costs to keep around, and that needs deltas kept
/// somewhere.
final class EnergyLedgerTests: XCTestCase {

    private func sample(
        pid: Int32, started: UInt64, nanojoules: UInt64,
        bundle: String? = "/Applications/Example.app"
    ) -> EnergySample {
        EnergySample(
            pid: pid,
            executablePath: "\(bundle ?? "/usr/bin/tool")/Contents/MacOS/Example",
            bundlePath: bundle,
            userTime: 0, systemTime: 0, diskReadBytes: 0, diskWriteBytes: 0, wakeups: 0,
            energyNanojoules: nanojoules, performanceCoreNanojoules: 0, startedAt: started
        )
    }

    private func result(_ samples: [EnergySample]) -> EnergySampleResult {
        EnergySampleResult(samples: samples, coverageGaps: 0)
    }

    func testTheFirstSightOfAProcessCountsEverythingItHasSpent() {
        let ledger = EnergyLedger().accumulating(
            result([sample(pid: 1, started: 100, nanojoules: 3_600_000_000_000)])
        )
        XCTAssertEqual(ledger.milliwattHours(for: "/Applications/Example.app"), 1000, accuracy: 0.01)
    }

    func testOnlyTheDifferenceIsAddedAfterwards() {
        var ledger = EnergyLedger().accumulating(
            result([sample(pid: 1, started: 100, nanojoules: 1_000_000_000_000)])
        )
        ledger = ledger.accumulating(
            result([sample(pid: 1, started: 100, nanojoules: 3_600_000_000_000)])
        )
        // The total is the latest reading, not the sum of both readings.
        XCTAssertEqual(ledger.milliwattHours(for: "/Applications/Example.app"), 1000, accuracy: 0.01)
    }

    func testARestartedProcessKeepsWhatItSpentBefore() {
        // The counter goes back to zero when an application relaunches.
        // Losing that history is the whole reason a ledger exists.
        var ledger = EnergyLedger().accumulating(
            result([sample(pid: 1, started: 100, nanojoules: 3_600_000_000_000)])
        )
        ledger = ledger.accumulating(
            result([sample(pid: 77, started: 500, nanojoules: 3_600_000_000_000)])
        )
        XCTAssertEqual(ledger.milliwattHours(for: "/Applications/Example.app"), 2000, accuracy: 0.01)
    }

    func testAReusedPidDoesNotInheritTheLastProcessesTotal() {
        // Pids come round again within an uptime. Without the start time
        // the new process looks like the old one, its lower counter reads
        // as a negative delta, and its real usage is lost.
        var ledger = EnergyLedger().accumulating(
            result([sample(pid: 1, started: 100, nanojoules: 7_200_000_000_000)])
        )
        ledger = ledger.accumulating(
            result([sample(pid: 1, started: 900, nanojoules: 3_600_000_000_000)])
        )
        XCTAssertEqual(
            ledger.milliwattHours(for: "/Applications/Example.app"), 3000, accuracy: 0.01,
            "The second process's energy was thrown away as a negative delta"
        )
    }

    func testHelpersRollIntoTheApplicationTheyBelongTo() {
        // Nothing can be done about "Claude Helper (Renderer)" except
        // close Claude, so the application is the only level worth a row.
        let ledger = EnergyLedger().accumulating(result([
            sample(pid: 1, started: 100, nanojoules: 1_800_000_000_000),
            sample(pid: 2, started: 200, nanojoules: 1_800_000_000_000),
        ]))
        XCTAssertEqual(ledger.milliwattHours(for: "/Applications/Example.app"), 1000, accuracy: 0.01)
        XCTAssertEqual(ledger.ranked().count, 1, "Two helpers became two rows")
    }

    func testSomethingWithNoBundleIsKeyedByItsExecutable() {
        let ledger = EnergyLedger().accumulating(
            result([sample(pid: 1, started: 100, nanojoules: 3_600_000_000_000, bundle: nil)])
        )
        XCTAssertEqual(ledger.ranked().first?.key, "/usr/bin/tool/Contents/MacOS/Example")
    }

    func testTheLedgerSurvivesBrimQuitting() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("energy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = EnergyLedgerStore(directoryURL: directory)
        let ledger = EnergyLedger().accumulating(
            result([sample(pid: 1, started: 100, nanojoules: 3_600_000_000_000)])
        )
        try store.save(ledger)

        // A different store object, as a later launch would have.
        let reopened = EnergyLedgerStore(directoryURL: directory).load()
        XCTAssertEqual(
            reopened.milliwattHours(for: "/Applications/Example.app"), 1000, accuracy: 0.01,
            "T-5.5 asks for energy that accumulates across app restarts"
        )
    }

    func testAnAbsentLedgerStartsEmptyRatherThanFailing() {
        let store = EnergyLedgerStore(
            directoryURL: URL(fileURLWithPath: "/tmp/brim-no-such-\(UUID().uuidString)")
        )
        XCTAssertTrue(store.load().totals.isEmpty)
    }
}

/// A battery, and the share of one a number of joules represents.
final class BatteryCapacityTests: XCTestCase {

    func testDesignEnergyIsCapacityTimesVoltage() {
        // The real shape from this Mac: DesignCapacity lives inside
        // BatteryData, Voltage at the top level.
        let capacity = BatteryCapacity.from(registry: [
            "Voltage": 12336,
            "BatteryData": ["DesignCapacity": 4629],
        ])
        XCTAssertEqual(capacity?.designMilliwattHours ?? 0, 57_103, accuracy: 1)
    }

    func testTheOlderTopLevelKeyStillWorks() {
        let capacity = BatteryCapacity.from(registry: [
            "Voltage": 12000, "DesignCapacity": 5000,
        ])
        XCTAssertEqual(capacity?.designMilliwattHours ?? 0, 60_000, accuracy: 1)
    }

    func testAMachineWithNoBatteryIsNotAFailure() {
        XCTAssertNil(BatteryCapacity.from(registry: [:]))
        XCTAssertNil(BatteryCapacity.from(registry: ["Voltage": 0, "DesignCapacity": 0]))
    }

    func testTheShareReadsAsAShareOfAFullCharge() {
        let capacity = BatteryCapacity(designMilliwattHours: 57_103)
        // contactsd on this Mac: 8734 J, which is 2426 mWh.
        XCTAssertEqual(capacity.share(ofMilliwattHours: 2426), 4.25, accuracy: 0.05)
        XCTAssertEqual(capacity.sentence(forMilliwattHours: 2426), "4.2% of a full charge")
    }

    func testSomethingTooSmallToMatterSaysNothing() {
        let capacity = BatteryCapacity(designMilliwattHours: 57_103)
        XCTAssertNil(capacity.sentence(forMilliwattHours: 1))
    }
}

/// T-5.6's acceptance criterion.
final class BatteryLifeProjectionTests: XCTestCase {

    /// No string in the product projects future battery life in time
    /// units.
    ///
    /// A projection depends on what the machine does next, which nobody
    /// knows. A figure in minutes reads as a promise, and the first time
    /// it is wrong every other number in the product is suspect too.
    func testNothingPromisesHowLongTheBatteryWillLast() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()

        let forbidden = [
            "hours of battery", "minutes of battery", "battery life remaining",
            "hours remaining", "minutes remaining", "time remaining",
            "will last", "estimated battery",
        ]

        for directory in ["BrimCore/Sources", "Brim"] {
            let walker = FileManager.default.enumerator(
                at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil
            )
            while let file = walker?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                let text = try String(contentsOf: file, encoding: .utf8).lowercased()
                for phrase in forbidden {
                    XCTAssertFalse(
                        text.contains(phrase),
                        "\(file.lastPathComponent) projects battery life with \"\(phrase)\". "
                        + "Energy is stated as what was used, never as time left."
                    )
                }
            }
        }
    }
}
