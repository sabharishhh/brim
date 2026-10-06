import Foundation

/// What Space measured on one visit, kept so the next visit can say what
/// changed.
///
/// History is snapshots and subtraction (`CLAUDE.md`): nothing watches the
/// disk between visits. Each finished visit records the figures it showed,
/// and "Since you last looked" is the latest of these subtracted from the
/// one before. With only one there is nothing to compare, and the card says
/// so rather than showing a row of zeros.
public struct SpaceSnapshot: Codable, Sendable, Equatable {
    public let date: Date
    public let used: Int64
    public let free: Int64
    /// Each row of "What software takes", by its title.
    public let rows: [String: Int64]
    /// Each application's bundle and data together, by name.
    public let apps: [String: Int64]

    public init(date: Date, used: Int64, free: Int64, rows: [String: Int64], apps: [String: Int64]) {
        self.date = date
        self.used = used
        self.free = free
        self.rows = rows
        self.apps = apps
    }
}

/// One thing that grew or shrank between two visits.
public struct SpaceChange: Identifiable, Sendable, Equatable {
    public let title: String
    public let bytes: Int64

    public var id: String {
        title
    }

    public init(title: String, bytes: Int64) {
        self.title = title
        self.bytes = bytes
    }
}

public enum SpaceHistory {
    static let key = "space.snapshots"
    /// Visits closer together than this are one look, not two.
    static let sameLook: TimeInterval = 3600
    static let kept = 30
    /// Changes smaller than this are noise: caches breathe by that much.
    static let worthSaying: Int64 = 100_000_000

    public static func load(_ defaults: UserDefaults = .standard) -> [SpaceSnapshot] {
        guard let data = defaults.data(forKey: key),
              let snapshots = try? JSONDecoder().decode([SpaceSnapshot].self, from: data) else { return [] }
        return snapshots
    }

    /// Adds a visit, replacing the latest when it was part of the same look.
    public static func record(_ snapshot: SpaceSnapshot, _ defaults: UserDefaults = .standard) {
        var snapshots = load(defaults)
        if let last = snapshots.last, snapshot.date.timeIntervalSince(last.date) < sameLook {
            snapshots.removeLast()
        }
        snapshots.append(snapshot)
        if let data = try? JSONEncoder().encode(Array(snapshots.suffix(kept))) {
            defaults.set(data, forKey: key)
        }
    }

    /// The most recent visit before this look.
    public static func previous(to date: Date, in snapshots: [SpaceSnapshot]) -> SpaceSnapshot? {
        snapshots.last { date.timeIntervalSince($0.date) >= sameLook }
    }

    /// What grew or shrank by enough to mention, largest first, rows and
    /// apps together. An app that is new or gone counts from or to nothing.
    public static func changes(from old: SpaceSnapshot, to new: SpaceSnapshot, limit: Int = 4) -> [SpaceChange] {
        func deltas(_ before: [String: Int64], _ after: [String: Int64]) -> [SpaceChange] {
            Set(before.keys).union(after.keys).map { name in
                SpaceChange(title: name, bytes: (after[name] ?? 0) - (before[name] ?? 0))
            }
        }
        return (deltas(old.rows, new.rows) + deltas(old.apps, new.apps))
            .filter { abs($0.bytes) >= worthSaying }
            .sorted { abs($0.bytes) > abs($1.bytes) || (abs($0.bytes) == abs($1.bytes) && $0.title < $1.title) }
            .prefix(limit)
            .map(\.self)
    }
}
