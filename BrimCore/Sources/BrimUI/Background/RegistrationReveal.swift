import BrimCore
import Foundation

public extension Registration {
    /// The application this runs, when its program sits inside one: the
    /// innermost bundle, so a helper app inside an app is the helper.
    ///
    /// Read from the path's components, never by walking up with
    /// `deleteLastPathComponent`. That walk stopped only at "/", and a
    /// launch job is somebody else's file: a `Program` ending in ".."
    /// grows with every step instead of reaching the root, so drawing
    /// the Background page would never finish (`CLAUDE.md`, on parent
    /// folder walks).
    var enclosingApplication: URL? {
        guard let programPath, programPath.hasPrefix("/") else { return nil }
        let components = URL(fileURLWithPath: programPath).standardizedFileURL.pathComponents
        guard let bundle = components.lastIndex(where: { $0.count > 4 && $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...bundle])))
    }

    /// Shared stores supply evidence, never an app-specific Finder target.
    var revealCandidatePaths: [String] {
        // A program that is gone has nothing to show in Finder. Settings
        // offers Show in Finder for a stale privacy entry and it does
        // nothing, so Brim does not offer it.
        if kind == .privacyGrant, isStale {
            return []
        }
        return switch kind {
        case .backgroundItem, .legacyLoginItem, .firewallEntry, .privacyGrant, .systemExtension, .configurationProfile:
            [programPath].compactMap(\.self)
        default:
            [recordPath, programPath].compactMap(\.self)
        }
    }
}
