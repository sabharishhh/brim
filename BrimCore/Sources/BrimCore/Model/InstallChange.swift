import Foundation

/// One application as it stood at one moment.
///
/// The unit of the append-only history. Nothing is updated in place and
/// nothing is derived and stored: a snapshot is written, and what changed
/// is worked out afterwards by subtracting one from another. That is why
/// there is no watcher process and nothing running at login.
public struct InstallObservation: Equatable, Sendable, Codable {
    public let bundleID: String
    public let name: String
    public let version: String?
    public let bundlePath: String?
    public let sizeBytes: Int64?
    /// When the bundle arrived on this Mac.
    public let addedAt: Date?
    /// When it was last opened, as far as Spotlight knows.
    public let lastUsedAt: Date?
    public let observedAt: Date

    public init(
        bundleID: String, name: String, version: String? = nil,
        bundlePath: String? = nil, sizeBytes: Int64? = nil,
        addedAt: Date? = nil, lastUsedAt: Date? = nil,
        observedAt: Date = Date()
    ) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.bundlePath = bundlePath
        self.sizeBytes = sizeBytes
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
        self.observedAt = observedAt
    }
}

/// What is different since last time Brim looked.
///
/// Derived by subtraction, never watched. A resident process that
/// notices installations is the thing every competitor ships and the
/// thing nobody wants running: it costs battery, it needs permissions,
/// and it is one more daemon on a Mac whose whole complaint is that it
/// has too many. Two snapshots and a difference answer the same question
/// for nothing.
public struct InstallChange: Equatable, Sendable, Codable {
    public enum Kind: Equatable, Sendable, Codable {
        case appeared
        case disappeared
        case updated(from: String?, to: String?)
        /// Same version, but the footprint moved by more than noise.
        case grew(by: Int64)
        case shrank(by: Int64)
    }

    public let kind: Kind
    public let bundleID: String
    public let name: String
    public let since: Date
    public let until: Date

    public init(kind: Kind, bundleID: String, name: String, since: Date, until: Date) {
        self.kind = kind
        self.bundleID = bundleID
        self.name = name
        self.since = since
        self.until = until
    }

    /// The consequence, not the category.
    public var sentence: String {
        switch kind {
        case .appeared:
            return "\(name) was installed."
        case .disappeared:
            return "\(name) was removed."
        case .updated(let from, let to):
            guard let from, let to else { return "\(name) was updated." }
            return "\(name) went from \(from) to \(to)."
        case .grew(let bytes):
            return "\(name) grew by \(ByteText.short(bytes)), same version."
        case .shrank(let bytes):
            return "\(name) shrank by \(ByteText.short(bytes))."
        }
    }
}

/// What Brim has seen happen on this Mac, derived from its own snapshots.
public struct InstallHistory: Equatable, Sendable, Codable {
    public let changes: [InstallChange]
    /// How many times Brim has looked. One means there is nothing to
    /// compare against yet, which is different from nothing changing.
    public let snapshots: Int

    public init(changes: [InstallChange], snapshots: Int) {
        self.changes = changes
        self.snapshots = snapshots
    }

    public var summary: String {
        if snapshots < 2 { return "First scan. Nothing to compare against yet." }
        if changes.isEmpty { return "No applications installed, removed or updated." }
        let count = changes.count
        return "\(count) \(count == 1 ? "change" : "changes") since the last scan."
    }
}
