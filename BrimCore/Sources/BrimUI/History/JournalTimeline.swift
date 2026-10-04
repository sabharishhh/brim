import BrimCore
import Foundation

/// One thing that happened, as the Journal lists it.
public struct JournalEntry: Identifiable, Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// Brim removed something, which may still be put back.
        case removed(RemovalRecord)
        /// An application first appeared, proved by a snapshot.
        case installed(url: URL)
    }

    public let id: String
    public let event: Event
    public let date: Date
    public let name: String
    public let bundleID: String?
    /// The time of day, written once when the entry is made (`CLAUDE.md`,
    /// on formatters).
    public let time: String

    public init(record: RemovalRecord) {
        id = "removed:" + record.id.uuidString
        event = .removed(record)
        date = record.plan.createdAt
        name = record.name
        bundleID = record.plan.intent.subjectIdentity.bundleID
        time = Self.timeStyle.format(date)
    }

    public init(installed app: InstalledApplication, on date: Date) {
        id = "installed:" + app.id
        event = .installed(url: app.url)
        self.date = date
        name = app.name
        bundleID = app.identity.bundleID
        time = Self.timeStyle.format(date)
    }

    private static let timeStyle = Date.FormatStyle.dateTime.hour().minute()
}

/// The Journal by time (plan §8): Today, Yesterday, This week, then one
/// group per month, newest first.
public enum JournalTimeline {
    public static func entries(records: [RemovalRecord], applications: [InstalledApplication]) -> [JournalEntry] {
        let installs = applications.compactMap { app in app.installedAt.map { JournalEntry(installed: app, on: $0) } }
        return (records.map(JournalEntry.init(record:)) + installs).sorted { $0.date > $1.date }
    }

    public static func groups(
        _ entries: [JournalEntry], now: Date = Date(), calendar: Calendar = .current
    ) -> [ItemGroup<JournalEntry>] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: today) ?? today

        var order: [String] = []
        var titles: [String: String] = [:]
        var buckets: [String: [JournalEntry]] = [:]
        for entry in entries.sorted(by: { $0.date > $1.date }) {
            let (key, title): (String, String)
            if entry.date >= today {
                (key, title) = ("today", "Today")
            } else if entry.date >= yesterday {
                (key, title) = ("yesterday", "Yesterday")
            } else if entry.date >= week {
                (key, title) = ("week", "This week")
            } else {
                let parts = calendar.dateComponents([.year, .month], from: entry.date)
                key = "\(parts.year ?? 0)-\(parts.month ?? 0)"
                let sameYear = parts.year == calendar.component(.year, from: now)
                title = (sameYear ? monthStyle : monthYearStyle).format(entry.date)
            }
            if buckets[key] == nil {
                order.append(key)
                titles[key] = title
            }
            buckets[key, default: []].append(entry)
        }
        return order.map { ItemGroup(id: $0, title: titles[$0] ?? $0, items: buckets[$0] ?? []) }
    }

    private static let monthStyle = Date.FormatStyle.dateTime.month(.wide)
    private static let monthYearStyle = Date.FormatStyle.dateTime.month(.wide).year()
}
