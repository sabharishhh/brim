import Foundation

/// What a location in the Library is for, and so what removing it costs:
/// a cache is rebuilt, Application Support holds settings and licences.
/// macOS assigns these meanings, so they are facts about the path.
public enum LeftoverDomain: String, Sendable, Codable, Equatable, CaseIterable {
    case cache
    case applicationSupport
    case preferences
    case logs
    case savedState
    case webData
    case container
    case groupContainer
    case launchAgent
    /// The per-user, per-boot folders under `/var/folders`, which macOS hands
    /// out through `confstr` and which hold real application data.
    case darwinPerUser
    case other

    /// Derives the domain from where the item sits. Order matters: several
    /// of these are nested under others.
    public static func of(_ url: URL) -> LeftoverDomain {
        let path = url.path
        func inLibrary(_ component: String) -> Bool {
            path.contains("/Library/\(component)/")
        }

        if isDarwinPerUser(path) { return .darwinPerUser }

        if inLibrary("Caches") { return .cache }
        if inLibrary("Application Support") { return .applicationSupport }
        if inLibrary("Preferences") { return .preferences }
        if inLibrary("Logs") { return .logs }
        if inLibrary("Saved Application State") { return .savedState }
        if inLibrary("HTTPStorages") || inLibrary("WebKit") || inLibrary("Cookies") { return .webData }
        if inLibrary("Group Containers") { return .groupContainer }
        if inLibrary("Containers") { return .container }
        if inLibrary("LaunchAgents") || inLibrary("LaunchDaemons") { return .launchAgent }
        return .other
    }

    /// Recognised by shape, not a stored path: `confstr` answers differently per
    /// user and per boot, and fixtures use stand-ins under the same prefix.
    static func isDarwinPerUser(_ path: String) -> Bool {
        guard let range = path.range(of: "/var/folders/") else { return false }
        let rest = path[range.upperBound...]
        // The real shape is `<xx>/<yyyy>/C/…` or `/T/…`. The fixture root's
        // stand-ins are `DarwinUserCache` and `DarwinUserTemp`.
        if rest.hasPrefix("DarwinUserCache") || rest.hasPrefix("DarwinUserTemp") { return true }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return false }
        return parts[2] == "C" || parts[2] == "T"
    }

    /// A short name for the column and the group header.
    public var title: String {
        switch self {
        case .cache: return "Cache"
        case .applicationSupport: return "App data"
        case .preferences: return "Settings"
        case .logs: return "Logs"
        case .savedState: return "Window state"
        case .webData: return "Web data"
        case .container: return "Sandbox container"
        case .groupContainer: return "Shared container"
        case .launchAgent: return "Background job"
        case .darwinPerUser: return "Working files"
        case .other: return "Other"
        }
    }

    /// What is actually in there, in a sentence a person can act on.
    public var whatItHolds: String {
        switch self {
        case .cache:
            return "Temporary files. The app can rebuild them."
        case .applicationSupport:
            return "App data may include settings, licences, and saved work."
        case .preferences:
            return "Settings. Removing them restores the app's defaults."
        case .logs:
            return "Diagnostic logs. The app can write new ones."
        case .savedState:
            return "Open windows and their positions. Rebuilt on launch."
        case .webData:
            return "Cookies and web files. Removing them may sign you out."
        case .container:
            return "The app's private data."
        case .groupContainer:
            return "Data shared with extensions or related apps."
        case .launchAgent:
            return "A background task registered with macOS."
        case .darwinPerUser:
            return "Temporary working files under /var/folders."
        case .other:
            return "Files outside the usual app folders."
        }
    }

    /// Whether the app regenerates this on its own: the most useful fact for
    /// deciding.
    public var isRegenerated: Bool {
        switch self {
        case .cache, .logs, .savedState, .darwinPerUser: return true
        case .applicationSupport, .preferences, .webData, .container,
             .groupContainer, .launchAgent, .other: return false
        }
    }

    /// A short verdict for the row about consequence, not a recommendation.
    /// Worded as what would happen, since it shows before anything is removed.
    public var consequence: String {
        isRegenerated ? "Comes back on its own" : "Goes to the Trash when removed"
    }
}
