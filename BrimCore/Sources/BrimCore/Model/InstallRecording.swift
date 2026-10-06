import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// The places software puts things, listed at one moment.
///
/// Paths only: the entries of every location in `LocationInventory`, one
/// level deeper where a developer's folder holds a product's, the home
/// folder's dot folders, and the background items macOS has accepted.
/// Recording an install is two of these and a subtraction. Nothing runs
/// between them, including while Brim is closed.
public struct InstallSnapshot: Codable, Sendable, Equatable {
    /// An application found in an Applications folder.
    public struct AppMark: Codable, Sendable, Equatable {
        public let identifier: String?
        public let version: String?
        /// What it is called: its file, its bundle name, its executable.
        public let names: [String]

        public init(identifier: String?, version: String?, names: [String]) {
            self.identifier = identifier
            self.version = version
            self.names = names
        }
    }

    /// A background item, as macOS's own record names it.
    public struct BackgroundMark: Codable, Sendable, Equatable {
        public let label: String
        public let bundleIdentifier: String?
        public let path: String?

        public init(label: String, bundleIdentifier: String?, path: String?) {
            self.label = label
            self.bundleIdentifier = bundleIdentifier
            self.path = path
        }
    }

    public let takenAt: Date
    public let paths: Set<String>
    /// By bundle path.
    public let apps: [String: AppMark]
    /// By a key stable across reads of the same record.
    public let backgroundItems: [String: BackgroundMark]
    /// Locations that could not be listed, so nothing there can be said
    /// to have appeared.
    public let unreadable: [String]

    public init(takenAt: Date, paths: Set<String>, apps: [String: AppMark],
                backgroundItems: [String: BackgroundMark], unreadable: [String]) {
        self.takenAt = takenAt
        self.paths = paths
        self.apps = apps
        self.backgroundItems = backgroundItems
        self.unreadable = unreadable
    }
}

/// An application an install put down or changed.
public struct RecordedApp: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let name: String
    public let bundleID: String?
    public let path: String
    public let version: String?
    /// It was here before, at another version.
    public let wasUpdated: Bool
    public let names: [String]

    public var id: String {
        path
    }

    public init(name: String, bundleID: String?, path: String, version: String?, wasUpdated: Bool, names: [String]) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.version = version
        self.wasUpdated = wasUpdated
        self.names = names
    }
}

/// Something that appeared while an install was recorded.
public struct RecordedItem: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let path: String
    /// Why it is linked to the install, in a few words.
    public let why: String
    /// The app it is named for, by bundle path, if any.
    public let app: String?
    /// A background item macOS recorded, rather than a file.
    public let isRegistration: Bool

    public var id: String {
        (isRegistration ? "registration:" : "") + path
    }

    public init(path: String, why: String, app: String?, isRegistration: Bool = false) {
        self.path = path
        self.why = why
        self.app = app
        self.isRegistration = isRegistration
    }
}

/// A recording the person kept: the apps it installed, and what it created.
public struct InstallRecording: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let apps: [RecordedApp]
    public let items: [RecordedItem]

    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date, apps: [RecordedApp], items: [RecordedItem]) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.apps = apps
        self.items = items
    }

    /// Whether this recording is about the application with this identifier.
    public func concerns(_ bundleID: String) -> Bool {
        apps.contains { $0.bundleID?.lowercased() == bundleID.lowercased() }
    }

    /// The sentence a row shows for anything this recording kept.
    public func evidence(for app: String) -> String {
        "Appeared when you installed \(app) on " + endedAt.formatted(.dateTime.day().month(.wide)) + "."
    }
}

/// What a finished recording found, before the person decides what to keep.
public struct InstallRecordingResult: Sendable, Equatable {
    public let startedAt: Date
    public let endedAt: Date
    public let apps: [RecordedApp]
    /// Named for one of the apps, from its developer, or registered by it.
    public let linked: [RecordedItem]
    /// Appeared while recording, and nothing names an owner.
    public let unclaimed: [RecordedItem]
    /// Appeared while recording and named for another installed app.
    public let otherApps: [String: Int]
    public let unreadable: [String]

    public init(startedAt: Date, endedAt: Date, apps: [RecordedApp], linked: [RecordedItem],
                unclaimed: [RecordedItem], otherApps: [String: Int], unreadable: [String]) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.apps = apps
        self.linked = linked
        self.unclaimed = unclaimed
        self.otherApps = otherApps
        self.unreadable = unreadable
    }
}

/// An installed application, as attribution needs to know it.
public struct InstallClaimant: Sendable, Equatable {
    public let name: String
    public let bundleID: String?
    public let names: [String]

    public init(name: String, bundleID: String?, names: [String]) {
        self.name = name
        self.bundleID = bundleID
        self.names = names
    }
}
