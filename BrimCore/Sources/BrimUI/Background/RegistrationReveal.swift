import BrimCore
import Foundation

public extension Registration {
    /// The innermost application this program sits inside. Read from the
    /// path's components rather than by walking up: a launch job's `Program`
    /// ending in ".." never reaches the root.
    var enclosingApplication: URL? {
        guard let programPath, programPath.hasPrefix("/") else { return nil }
        let components = URL(fileURLWithPath: programPath).standardizedFileURL.pathComponents
        guard let bundle = components.lastIndex(where: { $0.count > 4 && $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...bundle])))
    }

    /// Shared stores supply evidence, never an app-specific Finder target.
    var revealCandidatePaths: [String] {
        // A program that is gone has nothing to show in Finder.
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
