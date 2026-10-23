import Foundation

/// Deterministic prose from the evidence model.
public struct ExplanationRenderer: Sendable {
    public init() {}

    /// What a plan step says about itself, in one or two sentences. `found` is
    /// the sentence the evidence source wrote when it matched, which knows which
    /// rule fired. The tier sentence is added only where it adds something: a
    /// shared item, or a match resting on a name.
    public func render(
        tier: EvidenceTier, capability: Capability, mechanism: String, found: String = ""
    ) -> String {
        let opening = found.isEmpty ? renderMechanism(mechanism: mechanism) : sentence(found)
        let components = [opening, renderConfidence(tier: tier), renderCapability(capability: capability)]
        return components.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Sources write their sentences without a full stop; here they are prose.
    private func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?:".contains(last) else { return trimmed }
        return trimmed + "."
    }

    /// Produces a human-readable explanation for an excluded item.
    public func renderRefusal(reason: String) -> String {
        // Keeping the application is what a reset is for, so it is not reported as
        // a refusal.
        if reason.contains("Preserved main application bundle") {
            return "Kept. The app needs it to run."
        }
        // The claimant's name is the evidence, so it stays.
        if reason.hasPrefix("Shared with "), reason != "Shared with other installed software." {
            let name = reason.dropFirst("Shared with ".count).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return "Shared with \(name), which is still installed."
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
        case "AppBundleSource": "The application itself."
        case "LaunchdSource": "A background job registered with macOS."
        case "SMAppServiceSource": "A helper the application registered to run in the background."
        case "GroupContainerSource": "A shared folder the application's own entitlements name."
        case "SandboxContainerSource": "The private folder macOS keeps for this application."
        case "InstallerReceiptSource": "The installer's record of this package."
        case "InstallerPayloadSource": "Installed by the same installer as the application."
        case "TeamIDSource": "Signed by the same developer as the application."
        case "BundleIdentifierComponentSource": "Named after the application's bundle identifier."
        case "DirectTarget": "You picked this one."
        default: "Found while tracing this application."
        }
    }

    /// Only where it changes what someone would do. A and B are already
    /// explained by the source's sentence; C rests on a shared name, which is
    /// worth saying every time; S is a veto and must be unmissable.
    private func renderConfidence(tier: EvidenceTier) -> String {
        switch tier {
        case .S:
            "Other software installed here uses this too, so Brim leaves it alone."
        case .A, .B:
            ""
        case .C:
            "Matched on the name alone, so check it before removing it."
        }
    }

    private func renderCapability(capability: Capability) -> String {
        switch capability {
        case .ok:
            ""
        case .needsHelper:
            "An administrator password is needed to remove it."
        case .needsFullDiskAccess:
            "Full Disk Access is needed to remove it."
        case .refusedByOS:
            "macOS will not let anything remove this."
        }
    }
}
