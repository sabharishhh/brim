import XCTest
@testable import BrimCore

/// How the Mac is coping, from interfaces Apple publishes.
///
/// The constraint that shaped this: there is no public API for a CPU
/// temperature in degrees. Every tool that prints one on Apple Silicon reads
/// it through `IOHIDEventSystemClient` or raw SMC keys, both private and both
/// undocumented, and Apple has never shown a temperature anywhere in macOS,
/// Activity Monitor included.
///
/// `ProcessInfo.thermalState` is what Apple publishes, and it answers the
/// question somebody actually has. Nobody needs to know a core is at 87
/// degrees. They need to know whether the Mac is being slowed down to cool
/// itself, which is what the state says, in Apple's own terms.
final class SystemConditionTests: XCTestCase {

    func testEveryThermalStateMapsToAppleS() {
        XCTAssertEqual(SystemCondition.Thermal.of(.nominal), .normal)
        XCTAssertEqual(SystemCondition.Thermal.of(.fair), .slightlyElevated)
        XCTAssertEqual(SystemCondition.Thermal.of(.serious), .hot)
        XCTAssertEqual(SystemCondition.Thermal.of(.critical), .tooHot)
    }

    /// Only the two that mean the Mac is throttling get attention. A card
    /// that goes orange whenever a laptop is warm teaches people to ignore
    /// it by the second day.
    func testOnlyThrottlingIsWorthDrawingAttentionTo() {
        XCTAssertFalse(SystemCondition.Thermal.normal.isNoteworthy)
        XCTAssertFalse(SystemCondition.Thermal.slightlyElevated.isNoteworthy)
        XCTAssertTrue(SystemCondition.Thermal.hot.isNoteworthy)
        XCTAssertTrue(SystemCondition.Thermal.tooHot.isNoteworthy)
    }

    func testEveryStateSaysWhatItMeansForTheMachine() {
        for thermal in [SystemCondition.Thermal.normal, .slightlyElevated, .hot, .tooHot] {
            XCTAssertFalse(thermal.title.isEmpty, "\(thermal) has no title")
            XCTAssertFalse(thermal.meaning.isEmpty, "\(thermal) explains nothing")
            XCTAssertTrue(thermal.meaning.hasSuffix("."), thermal.meaning)
        }
    }

    // MARK: - The note, which is usually silence

    /// A cool Mac on the adapter has nothing to report, and a card that
    /// insists on saying so every time is one people stop reading.
    func testAHealthyMacSaysNothing() {
        let condition = SystemCondition(
            thermal: .normal, power: .adapterOnly, lowPowerMode: false
        )
        XCTAssertNil(condition.note)
    }

    func testThrottlingIsSaidBeforeAnythingElse() {
        let condition = SystemCondition(
            thermal: .hot, power: .battery(percent: 12), lowPowerMode: true
        )
        XCTAssertEqual(condition.note, SystemCondition.Thermal.hot.meaning)
    }

    func testLowPowerModeIsExplainedRatherThanFlagged() {
        let condition = SystemCondition(
            thermal: .normal, power: .adapterOnly, lowPowerMode: true
        )
        XCTAssertTrue(condition.note?.contains("deliberately") ?? false, condition.note ?? "nil")
    }

    func testARunningLowBatteryChangesWhatTheNumbersMean() {
        let condition = SystemCondition(
            thermal: .normal, power: .battery(percent: 8), lowPowerMode: false
        )
        XCTAssertNotNil(condition.note)
    }

    // MARK: - Power

    func testTheAdapterMeansNothingHereCostsAnything() {
        XCTAssertFalse(SystemCondition.Power.adapterOnly.isOnBattery)
        XCTAssertFalse(SystemCondition.Power.chargingFromAdapter(percent: 40).isOnBattery)
        XCTAssertTrue(SystemCondition.Power.battery(percent: 40).isOnBattery)
    }

    func testEveryPowerStateReadsAsASentenceFragment() {
        XCTAssertEqual(SystemCondition.Power.battery(percent: 63).title, "On battery, 63%")
        XCTAssertEqual(SystemCondition.Power.chargingFromAdapter(percent: 63).title, "Charging, 63%")
        XCTAssertEqual(SystemCondition.Power.adapterOnly.title, "Plugged in")
    }

    // MARK: - Against the real machine

    func testTheRealReadUsesApplesOwnInterfaces() {
        // No private API, no shelling out, no sudo. If this ever needs one
        // of those it is the wrong feature.
        let condition = SystemCondition.current()
        XCTAssertFalse(condition.thermal.title.isEmpty)
        // Power is nil on a desktop, which is an answer rather than a
        // failure, so nothing is asserted about it.
    }
}
