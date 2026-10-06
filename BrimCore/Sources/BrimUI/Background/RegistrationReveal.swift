import BrimCore

public extension Registration {
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
