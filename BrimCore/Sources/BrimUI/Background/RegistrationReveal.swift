import BrimCore

public extension Registration {
    /// Shared stores supply evidence, never an app-specific Finder target.
    var revealCandidatePaths: [String] {
        switch kind {
        case .backgroundItem, .legacyLoginItem, .firewallEntry, .privacyGrant, .systemExtension, .configurationProfile:
            [programPath].compactMap(\.self)
        default:
            [recordPath, programPath].compactMap(\.self)
        }
    }
}
