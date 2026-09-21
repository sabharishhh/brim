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
            return "\(name) is gone. Anything it left behind is in Leftovers."
        case .updated(let from, let to):
            guard let from, let to else { return "\(name) was updated." }
            return "\(name) went from \(from) to \(to)."
        case .grew(let bytes):
            return "\(name) grew by \(ByteText.short(bytes)) without changing version."
        case .shrank(let bytes):
            return "\(name) shrank by \(ByteText.short(bytes))."
        }
    }
}

/// Software that came across from another Mac and never ran here.
///
/// Migration Assistant copies everything, which is its job, and a good
/// third of what it copies is never opened again. These are the safest
/// removals on the machine and nothing surfaces them, because the only
/// evidence is two dates that nobody thinks to compare.
public enum MigrationHygiene {

    public enum Verdict: Equatable, Sendable, Codable {
        /// Opened on this Mac since it arrived. Ordinary software.
        case inUse
        /// The bundle arrived, and the last time anybody opened it was
        /// before it got here. The usage record came across with it.
        case cameAcrossAndNeverRan(lastUsedElsewhere: Date)
        /// Older than this installation of macOS, so it predates the
        /// Mac it is sitting on.
        case predatesThisSystem
        /// Never opened, ever, as far as Spotlight knows.
        case neverOpened
        /// Not enough to say. Spotlight is off, or the dates are absent.
        case unknown(String)

        /// Whether this is worth putting in front of somebody.
        public var isWorthReviewing: Bool {
            switch self {
            case .inUse, .unknown: return false
            case .cameAcrossAndNeverRan, .predatesThisSystem, .neverOpened: return true
            }
        }

        public var sentence: String {
            switch self {
            case .inUse:
                return "You have used this since it arrived."
            case .cameAcrossAndNeverRan(let when):
                let formatted = Verdict.formatter.string(from: when)
                return "This came across from another Mac. The last time it was opened was "
                     + "\(formatted), before it got here, so it has never run on this Mac."
            case .predatesThisSystem:
                return "This is older than this installation of macOS, so it came from a "
                     + "previous Mac or a previous system."
            case .neverOpened:
                return "Nothing has ever opened this, as far as Spotlight knows."
            case .unknown(let why):
                return why
            }
        }

        static let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter
        }()
    }

    /// Judged on two dates and the system's own age.
    ///
    /// The sharp signal is not "older than the system", which catches
    /// almost nothing on a Mac restored from a backup: it is a last-used
    /// date *earlier than the date the bundle arrived*. That can only
    /// happen when the usage record travelled with the application and
    /// nobody has opened it since. Observed on this machine: IINA
    /// arrived on 14 September and was last opened on 7 August.
    ///
    /// A day of slack, because Spotlight writes both and they are not
    /// written atomically.
    public static func judge(
        addedAt: Date?,
        lastUsedAt: Date?,
        systemInstalledAt: Date?,
        slack: TimeInterval = 86_400
    ) -> Verdict {
        guard let addedAt else {
            return .unknown("Brim could not tell when this arrived on your Mac.")
        }

        guard let lastUsedAt else {
            return .neverOpened
        }

        if lastUsedAt < addedAt.addingTimeInterval(-slack) {
            return .cameAcrossAndNeverRan(lastUsedElsewhere: lastUsedAt)
        }

        if let systemInstalledAt, addedAt < systemInstalledAt.addingTimeInterval(-slack) {
            return .predatesThisSystem
        }

        return .inUse
    }
}

/// One application that came across and never ran here.
public struct MigratedApplication: Equatable, Sendable, Codable {
    public let application: InstalledApplication
    public let verdict: MigrationHygiene.Verdict
    public let sizeBytes: Int64

    public init(
        application: InstalledApplication,
        verdict: MigrationHygiene.Verdict,
        sizeBytes: Int64
    ) {
        self.application = application
        self.verdict = verdict
        self.sizeBytes = sizeBytes
    }
}

/// What Brim has seen happen on this Mac, derived from its own snapshots.
public struct InstallHistory: Equatable, Sendable, Codable {
    public let changes: [InstallChange]
    /// How many times Brim has looked. One means there is nothing to
    /// compare against yet, which is different from nothing changing.
    public let snapshots: Int
    public let migrated: [MigratedApplication]

    public init(changes: [InstallChange], snapshots: Int, migrated: [MigratedApplication]) {
        self.changes = changes
        self.snapshots = snapshots
        self.migrated = migrated
    }

    /// What the person is told, in one line.
    public var summary: String {
        if snapshots < 2 {
            return "This is the first time Brim has looked, so there is nothing to compare "
                 + "against yet. Next time it will say what changed."
        }
        if changes.isEmpty {
            return "Nothing has been installed, removed or updated since Brim last looked."
        }
        let count = changes.count
        return "\(count) \(count == 1 ? "thing has" : "things have") changed since Brim last "
             + "looked."
    }

    /// What the migrated software is worth, together.
    public var migratedBytes: Int64 {
        migrated.reduce(0) { $0 + $1.sizeBytes }
    }
}
