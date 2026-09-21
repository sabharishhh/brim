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
            return "Temporary files the app rebuilds by itself. Removing them frees space and "
                 + "costs nothing but a slower first launch."
        case .applicationSupport:
            return "The app's own data — settings, licences, saved work, databases. This is the "
                 + "one to look at before removing: if the app comes back, this is what it "
                 + "would have remembered."
        case .preferences:
            return "Settings only. The app starts with its defaults again if this goes."
        case .logs:
            return "Diagnostic output the app wrote for its own developers. Nothing depends on it."
        case .savedState:
            return "Which windows were open and where. Rebuilt the next time the app runs."
        case .webData:
            return "Cookies, local storage and cached pages from web content inside the app. "
                 + "Removing it signs you out of anything it was keeping you signed in to."
        case .container:
            return "A sandboxed app's private folder — everything it was allowed to keep, in "
                 + "one place."
        case .groupContainer:
            return "Data shared between an app and its extensions, or between apps from the "
                 + "same developer. Something else may still be using it."
        case .launchAgent:
            return "An instruction to macOS to run something in the background. Left behind, it "
                 + "either fails silently at every login or keeps running software you removed."
        case .other:
            return "Brim has no specific knowledge of this location."
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
        isRegenerated ? "Rebuilt automatically" : "Not recoverable once the Trash is emptied"
    }
}
