import BrimCore
@testable import BrimUI
import XCTest

/// The Journal reads by time, and keeps every install it can prove.
final class JournalTimelineTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private func install(_ name: String, on date: Date) -> InstallRecord {
        InstallRecord(bundleID: "com.example.\(name)", name: name,
                      bundlePath: "/Applications/\(name).app", installedAt: date)
    }

    func testEntriesFallIntoTodayYesterdayThisWeekThenMonths() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 12)))
        let dates = [0, -1, -3, -20, -300].compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
        let installs = dates.enumerated().map { install("App\($0.offset)", on: $0.element) }
        let entries = JournalTimeline.entries(records: [], installs: installs)

        let groups = JournalTimeline.groups(entries, now: now, calendar: calendar)

        XCTAssertEqual(groups.map(\.id), ["today", "yesterday", "week", "2026-9", "2025-12"])
        XCTAssertEqual(groups.map(\.items.count), [1, 1, 1, 1, 1])
    }

    /// Two installs of one app are two entries, and an app that has gone
    /// keeps its installs without claiming its bundle is still there.
    func testEachInstallIsItsOwnEntryEvenAfterTheAppHasGone() {
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = JournalTimeline.entries(
            records: [], installs: [install("Gone", on: first), install("Gone", on: first + 3600)]
        )
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
        XCTAssertTrue(entries.allSatisfy { !$0.isPresent })
    }
}
