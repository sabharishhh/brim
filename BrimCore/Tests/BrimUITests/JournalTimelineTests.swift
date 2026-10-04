import BrimCore
@testable import BrimUI
import XCTest

/// The Journal reads by time, and an install Brim cannot prove is not in it.
final class JournalTimelineTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private func app(_ name: String, installed: Date?) -> InstalledApplication {
        InstalledApplication(
            identity: Identity(bundleID: "com.example.\(name)", name: name),
            url: URL(fileURLWithPath: "/Applications/\(name).app"), bundleSizeBytes: 1, isSystemProtected: false,
            installedAt: installed
        )
    }

    func testEntriesFallIntoTodayYesterdayThisWeekThenMonths() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 12)))
        let dates = [0, -1, -3, -20, -300].compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
        let apps = dates.enumerated().map { app("App\($0.offset)", installed: $0.element) }
        let entries = JournalTimeline.entries(records: [], applications: apps)

        let groups = JournalTimeline.groups(entries, now: now, calendar: calendar)

        XCTAssertEqual(groups.map(\.id), ["today", "yesterday", "week", "2026-9", "2025-12"])
        XCTAssertEqual(groups.map { $0.items.count }, [1, 1, 1, 1, 1])
    }

    /// Spotlight's date added moves on every update, so only a snapshot
    /// proves an install. An app already here at the first scan has none,
    /// and listing it would claim an installation nobody saw.
    func testAnAppWithNoProvenInstallDateIsNotAnEvent() {
        let entries = JournalTimeline.entries(records: [], applications: [app("Old", installed: nil)])
        XCTAssertTrue(entries.isEmpty)
    }
}
