@testable import BrimCore
import Foundation
import IOKit.ps
import XCTest

/// The battery card says what System Settings says, and nothing ahead.
///
/// The values are this MacBook Air's on 6 October: 80% on a 35 W adapter,
/// holding its charge, the Mac drawing 17.1 W, health Good, 100% capacity
/// and 55 cycles. The registry's raw capacities give 98.5%, which is why
/// the capacity is read from the profiler rather than worked out.
final class BatteryReportTests: XCTestCase {
    private let source: [String: Any] = [
        kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 100,
        kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsChargingKey: false, kIOPSIsChargedKey: false
    ]

    private let registry: [String: Any] = [
        "PowerTelemetryData": ["SystemLoad": 17126, "SystemPowerIn": 17126],
        "AdapterDetails": ["Watts": 35, "Name": "35W USB-C Power Adapter "],
        "AppleRawMaxCapacity": 4561, "DesignCapacity": 4629
    ]

    private let profiler = Data("""
    {"SPPowerDataType":[{"_name":"spbattery_information",
      "sppower_battery_charge_info":{"sppower_battery_state_of_charge":80},
      "sppower_battery_health_info":{"sppower_battery_cycle_count":55,
        "sppower_battery_health":"Good","sppower_battery_health_maximum_capacity":"100%"}},
      {"_name":"sppower_ac_charger_information"}]}
    """.utf8)

    func testThisMacReadsAsSettingsShowsIt() throws {
        let report = try XCTUnwrap(BatteryReport.read(powerSource: source, registry: registry, profiler: profiler))
        XCTAssertEqual(report.percent, 80)
        XCTAssertEqual(report.charging, .pluggedInNotCharging)
        XCTAssertEqual(try XCTUnwrap(report.drawWatts), 17.126, accuracy: 0.001)
        XCTAssertEqual(report.adapterWatts, 35)
        XCTAssertEqual(report.health, BatteryReport.Health(
            condition: "Normal", needsService: false, maximumCapacity: 100, cycles: 55
        ))
    }

    func testAnythingButGoodIsServiceRecommended() throws {
        let text = try XCTUnwrap(String(bytes: profiler, encoding: .utf8))
        let worn = Data(text
            .replacingOccurrences(of: "\"Good\"", with: "\"Check Battery\"").utf8)
        let health = try XCTUnwrap(BatteryReport.health(fromProfiler: worn))
        XCTAssertEqual(health.condition, "Service Recommended")
        XCTAssertTrue(health.needsService)
    }

    func testOnBatteryNamesNoAdapter() throws {
        var unplugged = source
        unplugged[kIOPSPowerSourceStateKey] = kIOPSBatteryPowerValue
        let report = try XCTUnwrap(BatteryReport.read(powerSource: unplugged, registry: registry, profiler: nil))
        XCTAssertEqual(report.charging, .onBattery)
        XCTAssertNil(report.adapterWatts, "An adapter in the registry is not one that is connected")
        XCTAssertNil(report.health, "No profiler reading means no health line, not a guessed one")
    }

    func testAMacWithNoBatteryHasNoReport() {
        XCTAssertNil(BatteryReport.read(powerSource: nil, registry: registry, profiler: profiler))
    }

    func testMissingTelemetryDropsOnlyTheDraw() throws {
        let report = try XCTUnwrap(BatteryReport.read(powerSource: source, registry: [:], profiler: profiler))
        XCTAssertNil(report.drawWatts)
        XCTAssertEqual(report.percent, 80)
        XCTAssertNotNil(report.health)
    }
}
