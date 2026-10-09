import Foundation
import Observation

/// How current a surface's findings are.
///
/// Every surface says how old what it shows is, because a list with no
/// age reads as live, and a list from last week that reads as live is how
/// somebody removes a thing that has since come back into use.
public enum Freshness: Equatable, Sendable {
    /// Never looked. Not the same as having looked and found nothing.
    case notChecked
    case checking
    case checked(Date)
    /// Looked, and some places could not be read.
    case partial(Date, unread: Int)
    case failed(String)

    /// Older than this and the surface offers to look again.
    public static let staleAfter: TimeInterval = 24 * 60 * 60

    public func isStale(now: Date = .now) -> Bool {
        switch self {
        case let .checked(date), let .partial(date, _): now.timeIntervalSince(date) > Self.staleAfter
        case .notChecked, .failed: true
        case .checking: false
        }
    }
}

@MainActor
public extension Freshness {
    func sentence(now: Date = .now) -> String {
        switch self {
        case .notChecked: return "Not checked yet"
        case .checking: return "Checking…"
        case let .checked(date): return "Checked " + Self.age(of: date, now: now)
        case let .partial(date, unread):
            let places = unread == 1 ? "1 place" : "\(unread) places"
            return "Checked \(Self.age(of: date, now: now)). \(places) could not be read."
        case let .failed(reason): return "Could not check. \(reason)"
        }
    }

    /// Constructed once. Building one per row per frame is what made the
    /// history list heavy (`CLAUDE.md`).
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// "just now" under a minute, then "2 minutes ago", "3 hours ago". The
    /// one way Brim says how old something is; shown with a minute's
    /// refresh, never a second's.
    static func age(of date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : relative.localizedString(for: date, relativeTo: now)
    }
}

/// What the whole window shares, and what outlives a launch.
///
/// Section models own their scans (`SectionModels`); this owns what is
/// true of the person's use of Brim rather than of the Mac: what they
/// have already seen, and the icons of apps that are gone.
@MainActor
@Observable
public final class AppSession {
    public let visits: VisitMemory
    public let icons: IconMemory

    public init(directory: URL? = AppSession.standardDirectory, icons: IconMemory = .standard) {
        visits = VisitMemory(file: directory?.appendingPathComponent("visits.json"))
        self.icons = icons
    }

    public nonisolated static let standardDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Brim/Interface", isDirectory: true)
}

/// A small value saved as JSON beside the others. Missing or unreadable
/// reads as empty: these are conveniences, and a corrupt file should cost
/// someone their "new" dots, never their launch.
struct JSONFile<Value: Codable> {
    let url: URL?

    func read() -> Value? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func write(_ value: Value) {
        guard let url, let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
