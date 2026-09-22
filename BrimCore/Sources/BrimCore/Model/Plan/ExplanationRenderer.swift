import Foundation

/// T-6.3: Deterministic prose from the evidence model.
public struct ExplanationRenderer: Sendable {
    public init() {}
    
    /// What a plan step says about itself, in one or two sentences.
    ///
    /// `found` is the sentence the evidence source already wrote when it made
    /// the match, and it is always the better one, because the source knows
    /// which rule fired rather than only which type ran. "A cache folder
    /// keyed to the bundle identifier" against "The file path exactly matches
    /// the application's unique identifier. It is highly probable this
    /// belongs to the application based on developer naming conventions."
    ///
    /// The plan used to discard it and rebuild prose from the mechanism's
    /// class name, so the Applications pane and the uninstall sheet described
    /// the same row in different words, and the sheet drew the worse pair.
    /// Four rows of one plan carried the identical second sentence.
    ///
    /// The tier sentence survives only where it adds something the first
    /// sentence does not: a shared item, or a match that rests on a name.
    public func render(
        tier: EvidenceTier, capability: Capability, mechanism: String, found: String = ""
    ) -> String {
        let opening = found.isEmpty ? renderMechanism(mechanism: mechanism) : sentence(found)
        let components = [opening, renderConfidence(tier: tier), renderCapability(capability: capability)]
        return components.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Sources write their sentences without a full stop, being labels as
    /// much as sentences. Here they are read as prose.
    private func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?:".contains(last) else { return trimmed }
        return trimmed + "."
    }
    
    /// Produces a human-readable explanation for an excluded item.
    public func renderRefusal(reason: String) -> String {
        // Reset first. Keeping the application is what a reset is for, so
        // reporting it as a refusal reads as a failure of the thing the
        // person just asked for.
        if reason.contains("Preserved main application bundle") {
            return "Kept, so the application still runs."
        }
        if reason.contains("ResetFilter") || reason.contains("reset") {
            return "Kept: settings or licence material a reset preserves."
        }
        if reason.contains("Shared with") || reason.contains("Tier S veto") {
            return "Shared with other installed software."
        }
        if reason.contains("read-only") {
            return "macOS protects this location."
        }
        if reason.contains("SIP") || reason.contains("System Integrity Protection") {
            return "Protected by System Integrity Protection."
        }
        if reason.contains("strictly protected") || reason.contains("OS boundaries") {
            return "Protected by macOS."
        }
        return reason
    }
    
    /// The fallback, for a step whose source left no sentence of its own.
    private func renderMechanism(mechanism: String) -> String {
        switch mechanism {
        case "AppBundleSource": return "The application itself."
        case "LaunchdSource": return "A background job registered with macOS."
        case "SMAppServiceSource": return "A helper the application registered to run in the background."
        case "GroupContainerSource": return "A shared folder the application's own entitlements name."
        case "SandboxContainerSource": return "The private folder macOS keeps for this application."
        case "InstallerReceiptSource": return "The installer's record of this package."
        case "TeamIDSource": return "Signed by the same developer as the application."
        case "BundleIdentifierComponentSource": return "Named after the application's bundle identifier."
        case "HeuristicSource": return "Named after the application or its vendor."
        case "DirectTarget": return "You picked this one."
        default: return "Found while tracing this application."
        }
    }
    
    /// Added only where it changes what somebody would do.
    ///
    /// A and B both mean Brim matched something the system itself records,
    /// and the sentence above already says which, so repeating "it has a
    /// direct structural link to the application" under every row was filler
    /// that made the rows harder to tell apart rather than easier. C rests on
    /// a shared name and nothing more, which is worth saying every time. S is
    /// a veto and has to be unmissable.
    private func renderConfidence(tier: EvidenceTier) -> String {
        switch tier {
        case .S:
            return "Other software installed here uses this too, so Brim leaves it alone."
        case .A, .B:
            return ""
        case .C:
            return "Matched on the name alone, so check it before removing it."
        }
    }

    private func renderCapability(capability: Capability) -> String {
        switch capability {
        case .ok:
            return ""
        case .needsHelper:
            return "An administrator password is needed to remove it."
        case .needsFullDiskAccess:
            return "Full Disk Access is needed to remove it."
        case .refusedByOS:
            return "macOS will not let anything remove this."
        }
    }
}
