import Foundation

/// What a location in the Library is *for*, and therefore what removing it
/// actually costs.
///
/// This is the question the leftovers list was failing to answer. A row
/// reading `/Users/x/Library/Caches/Codex — 118.8 MB` tells a user nothing
/// they can act on: they cannot tell it apart from the `Application Support`
/// entry beside it, and nothing on screen says one is rebuilt automatically
/// while the other holds settings and licences.
///
/// The answer does not require judgement or a model. macOS assigns meaning
/// to these directories, and that meaning is a fact about the path.
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

        // `LocationInventory` has scanned `darwinUserCache` and
        // `darwinUserTemp` for some time and this classifier did not know
        // them, so everything found there arrived in the list badged "Other"
        // over the sentence "An unrecognised location." Brim recognised it
        // well enough to go looking; only the description did not.
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

    /// Recognised by shape rather than by a stored path.
    ///
    /// There is no path to hard-code: macOS answers `confstr` with a
    /// different `/var/folders/<xx>/<yyyy>` per user and per boot, and the
    /// fixture root uses stand-ins under the same prefix. Matching the
    /// structure covers both, and covers a path recorded on a previous boot.
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
            return "Scratch files the app makes again whenever it needs them. Clearing them frees "
                 + "space and costs you nothing but a slower first launch."
        case .applicationSupport:
            return "The app's own data: settings, licences, saved work, databases. Worth a look "
                 + "before you clear it. If you ever install the app again, this is what it "
                 + "would have remembered."
        case .preferences:
            return "Settings, and nothing else. The app goes back to its defaults without them."
        case .logs:
            return "Notes the app wrote for its own developers. Nothing depends on them."
        case .savedState:
            return "Which windows were open and where they sat. Written again next time the app runs."
        case .webData:
            return "Cookies and cached pages from web content inside the app. Clear it and you "
                 + "will be signed out of whatever it was keeping you signed in to."
        case .container:
            return "A sandboxed app's private folder, holding everything it was allowed to keep."
        case .groupContainer:
            return "Shared between an app and its extensions, or between apps from the same "
                 + "maker. Something else may still be reading it."
        case .launchAgent:
            return "A standing instruction for macOS to run something in the background. Left "
                 + "behind, it either fails quietly at every login or keeps running software "
                 + "you thought was gone."
        case .darwinPerUser:
            return "Scratch space macOS hands each application privately, under /var/folders. "
                 + "The app writes it again when it needs it. Nothing lists this folder, which "
                 + "is why what is in it outlasts the software by months."
        case .other:
            return "A location outside the folders macOS sets aside for applications."
        }
    }

    /// Whether the app regenerates this on its own. The single most useful
    /// fact for deciding, and the one the flat list never showed.
    public var isRegenerated: Bool {
        switch self {
        case .cache, .logs, .savedState, .darwinPerUser: return true
        case .applicationSupport, .preferences, .webData, .container,
             .groupContainer, .launchAgent, .other: return false
        }
    }

    /// A short verdict for the row. Deliberately about consequence rather
    /// than a recommendation: Brim says what is lost, the user decides.
    ///
    /// Shown on every location while nothing has been removed yet, so it
    /// has to read as what *would* happen, not as a claim about the Trash
    /// right now. The previous wording, "Gone once you empty the Trash",
    /// read as a present-tense statement about existing Trash contents to
    /// someone whose Trash was empty at the time, when it was only ever
    /// describing where a removal goes.
    public var consequence: String {
        isRegenerated ? "Comes back on its own" : "Goes to the Trash when removed"
    }
}
