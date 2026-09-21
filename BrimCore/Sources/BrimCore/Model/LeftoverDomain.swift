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
    case other

    /// Derives the domain from where the item sits. Order matters: several
    /// of these are nested under others.
    public static func of(_ url: URL) -> LeftoverDomain {
        let path = url.path
        func inLibrary(_ component: String) -> Bool {
            path.contains("/Library/\(component)/")
        }

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
        case .other:
            return "An unrecognised location."
        }
    }

    /// Whether the app regenerates this on its own. The single most useful
    /// fact for deciding, and the one the flat list never showed.
    public var isRegenerated: Bool {
        switch self {
        case .cache, .logs, .savedState: return true
        case .applicationSupport, .preferences, .webData, .container,
             .groupContainer, .launchAgent, .other: return false
        }
    }

    /// A short verdict for the row. Deliberately about consequence rather
    /// than a recommendation: Brim says what is lost, the user decides.
    public var consequence: String {
        isRegenerated ? "Comes back on its own" : "Gone once you empty the Trash"
    }
}
