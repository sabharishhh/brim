@testable import BrimCore
import Foundation
import XCTest

/// Reading power management's own log, with lines shaped as this Mac wrote
/// them on 5 and 6 October.
final class PowerLogTests: XCTestCase {
    private let now = date("2026-10-06 09:30:00")

    /// A night asleep on battery, with two maintenance wakes inside it.
    private var night: String {
        [
            line("2026-10-05 23:00:00", "Sleep", "Entering Sleep state due to 'Clamshell Sleep':"
                + "TCPKeepAlive=active Using Batt (Charge:82%) 3600 secs"),
            line("2026-10-06 01:00:00", "DarkWake", "DarkWake from Deep Idle [CDNP] : due to "
                + "NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/Maintenance Using BATT (Charge:81%) 20 secs"),
            line("2026-10-06 01:00:20", "Sleep", "Entering Sleep state due to 'Maintenance Sleep':"
                + "TCPKeepAlive=active Using Batt (Charge:81%) 7000 secs"),
            line("2026-10-06 03:00:00", "DarkWake", "DarkWake from Deep Idle [CDNP] : due to "
                + "smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty/ Using BATT (Charge:80%) 1 secs"),
            line("2026-10-06 03:00:01", "Sleep", "Entering Sleep state due to 'Maintenance Sleep':"
                + "TCPKeepAlive=active Using Batt (Charge:80%) 14000 secs"),
            line("2026-10-06 07:10:00", "Wake", "DarkWake to FullWake from Deep Idle [CDNVA] : due to "
                + "UserActivity Assertion Using BATT (Charge:78%)")
        ].joined(separator: "\n")
    }

    func testANightAsleepReadsAsOneStretchWithItsBriefWakes() throws {
        let history = PowerHistory.parse(night, now: now)
        let sleep = try XCTUnwrap(history.lastSleep)
        XCTAssertEqual(sleep.duration, 8 * 3600 + 10 * 60)
        XCTAssertEqual(sleep.briefWakes, 2)
        XCTAssertEqual(sleep.chargeUsed, 4)
        XCTAssertEqual(history.charge.count, 6)
        XCTAssertEqual(history.since, Self.date("2026-10-05 23:00:00"))
    }

    func testChargeOnTheAdapterSaysNothingAboutWhatSleepCost() throws {
        let plugged = night.replacingOccurrences(of: "Using BATT (Charge:80%)", with: "Using AC (Charge:80%)")
        let sleep = try XCTUnwrap(PowerHistory.parse(plugged, now: now).lastSleep)
        XCTAssertTrue(sleep.onAdapter)
        XCTAssertNil(sleep.chargeUsed, "A charge measured on the adapter is not what sleeping used")
    }

    /// Overlapping requests from one app count once; display requests and
    /// requests made for nobody in particular are left out.
    func testRequestsAreAddedUpPerAppWithOverlapsCountedOnce() {
        let log = [
            request("08:00:00", "2158(ChatGPT) Created NoIdleSleepAssertion \"Electron\" 00:00:00", id: 1),
            request("08:30:00", "2158(ChatGPT) Created NoIdleSleepAssertion \"Electron\" 00:00:00", id: 2),
            request("09:00:00", "2158(ChatGPT) Released NoIdleSleepAssertion \"Electron\" 01:00:00", id: 1),
            request("09:10:00", "2158(ChatGPT) Released NoIdleSleepAssertion \"Electron\" 00:40:00", id: 2),
            request("09:01:01", "406(runningboardd) Released PreventUserIdleSystemSleep "
                + "\"app<application.com.apple.Safari.512363.513029(501)>406-2171:Media\" 00:20:00", id: 3),
            request("09:01:01", "406(runningboardd) Released PreventUserIdleSystemSleep  00:20:00", id: 4),
            request("09:05:00", "41278(Safari) Released PreventUserIdleDisplaySleep \"WebCore\" 00:30:00", id: 5),
            request("09:20:00", "57895(Claude) Created NoIdleSleepAssertion \"Electron\" 00:00:00", id: 6)
        ].joined(separator: "\n")
        let requests = PowerHistory.parse(log, now: now).requests
        XCTAssertEqual(requests.map(\.requester), ["ChatGPT", "com.apple.Safari", "Claude"])
        XCTAssertEqual(requests[0].seconds, 70 * 60, "08:00 to 09:10 once, not 100 minutes")
        XCTAssertTrue(requests[1].isIdentifier)
        XCTAssertEqual(requests[1].seconds, 20 * 60)
        XCTAssertEqual(requests[2].seconds, 10 * 60, "Still held, so counted up to now")
    }

    func testOneAppAskingForItselfAndThroughABrokerCountsOnce() {
        let log = [
            request("08:00:00", "41278(Safari) Created PreventUserIdleSystemSleep \"Playback\" 00:00:00", id: 7),
            request("09:00:00", "41278(Safari) Released PreventUserIdleSystemSleep \"Playback\" 01:00:00", id: 7),
            request("09:00:00", "406(runningboardd) Released PreventUserIdleSystemSleep "
                + "\"app<application.com.apple.Safari.1.2(501)>:Media\" 00:30:00", id: 8)
        ].joined(separator: "\n")
        let names = ApplicationNames([
            .init(name: "Safari", path: "/Applications/Safari.app", executable: "Safari",
                  identifier: "com.apple.Safari"),
            .init(name: "Safari", path: "/System/Cryptexes/App/System/Applications/Safari.app",
                  executable: "Safari", identifier: "com.apple.Safari")
        ])
        let rows = PowerHistory.parse(log, now: now).requestsByApplication(names)
        XCTAssertEqual(rows.map(\.app.name), ["Safari"], "The system's own copy of Safari is not a second app")
        XCTAssertEqual(rows.first?.seconds, 3600, "The broker's half hour sits inside Safari's own hour")
    }

    func testAnAmbiguousExecutableNamesNobody() {
        let names = ApplicationNames([
            .init(name: "Visual Studio Code", path: "/Applications/Visual Studio Code.app",
                  executable: "Electron", identifier: "com.microsoft.VSCode"),
            .init(name: "Other", path: "/Applications/Other.app", executable: "Electron",
                  identifier: "com.example.other"),
            .init(name: "ChatGPT", path: "/Applications/ChatGPT.app", executable: "ChatGPT",
                  identifier: "com.openai.chat")
        ])
        func asked(_ name: String) -> PowerHistory.Request {
            PowerHistory.Request(requester: name, isIdentifier: false, spans: [])
        }
        XCTAssertNil(names.app(for: asked("Electron")), "Two apps answer to Electron, so neither is named")
        XCTAssertEqual(names.app(for: asked("ChatGPT"))?.name, "ChatGPT")
        XCTAssertNil(names.app(for: asked("powerd")), "A process no app answers to is macOS's own")
    }

    /// Runs on the real log. Prints what the page would show.
    func testTheRealLogParses() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BRIM_REAL_ENV"] == "1")
        let started = Date()
        let history = try XCTUnwrap(PowerHistory.current())
        print("power log read in", Date().timeIntervalSince(started), "s, since", history.since as Any)
        print("charge points", history.charge.count, "sleeps", history.sleeps.count)
        if let last = history.lastSleep {
            print("last sleep", last.span, "used", last.chargeUsed as Any, "brief wakes", last.briefWakes)
        }
        for row in history.requestsByApplication(.installed()) {
            print(String(format: "app %7.1f h", row.seconds / 3600), row.app.name)
        }
        XCTAssertFalse(history.charge.isEmpty)
    }

    // MARK: - Lines

    private static func date(_ text: String) -> Date {
        PowerLogEntry.date(text + " +0530") ?? .distantPast
    }

    private func line(_ time: String, _ domain: String, _ message: String) -> String {
        "\(time) +0530 " + domain.padding(toLength: 20, withPad: " ", startingAt: 0) + "\t" + message
    }

    private func request(_ time: String, _ body: String, id: Int) -> String {
        line("2026-10-06 " + time, "Assertions", "PID \(body)  id:0x0x\(id) [System: PrevIdle]")
    }
}
