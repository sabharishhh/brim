import XCTest
@testable import BrimCore

/// How the Mac is coping, from public interfaces only. There is no public
/// API for CPU temperature; `ProcessInfo.thermalState` says whether the Mac
/// is slowing down to cool itself, which is the question people have.
final class SystemConditionTests: XCTestCase {

    func testEveryThermalStateMapsToAppleS() {
        XCTAssertEqual(SystemCondition.Thermal.of(.nominal), .normal)
        XCTAssertEqual(SystemCondition.Thermal.of(.fair), .slightlyElevated)
        XCTAssertEqual(SystemCondition.Thermal.of(.serious), .hot)
        XCTAssertEqual(SystemCondition.Thermal.of(.critical), .tooHot)
    }

    /// Only the throttling states get attention; a card that turns orange
    /// whenever a laptop is warm gets ignored.
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

    /// A cool Mac on the adapter has nothing to report.
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
        XCTAssertTrue(condition.note?.contains("runs slower to save battery") ?? false, condition.note ?? "nil")
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
        // No private API, no shelling out, no sudo.
        let condition = SystemCondition.current()
        XCTAssertFalse(condition.thermal.title.isEmpty)
        // Power is nil on a desktop, which is an answer, so nothing is asserted.
    }
}
