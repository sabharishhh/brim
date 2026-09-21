import Foundation

/// T-6.3: Deterministic prose from the evidence model.
public struct ExplanationRenderer: Sendable {
    public init() {}
    
    /// Produces a human-readable explanation for a plan step based on evidence.
    public func render(tier: EvidenceTier, capability: Capability, mechanism: String) -> String {
        let confidenceProse = renderConfidence(tier: tier)
        let capabilityProse = renderCapability(capability: capability)
        let mechanismProse = renderMechanism(mechanism: mechanism)
        
        let components = [mechanismProse, confidenceProse, capabilityProse].filter { !$0.isEmpty }
        
        return components.joined(separator: " ")
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
    
    private func renderMechanism(mechanism: String) -> String {
        switch mechanism {
        case "AppBundleSource": return "This is the application bundle itself."
        case "LaunchdSource": return "This is a registered background service."
        case "SMAppServiceSource": return "This is a privileged helper or background agent embedded by the developer."
        case "GroupContainerSource": return "This group container is explicitly declared in the application's cryptographic entitlements."
        case "SandboxContainerSource": return "macOS maintains this isolated sandbox container strictly for this application."
        case "InstallerReceiptSource": return "An installer receipt proves this package was installed."
        case "TeamIDSource": return "This directory is signed by the developer's Team ID."
        case "BundleIdentifierComponentSource": return "The file path exactly matches the application's unique identifier."
        case "HeuristicSource": return "The file name closely matches the application or vendor name."
        case "DirectTarget": return "You specifically requested to include this target."
        default: return "This item is associated with the application's footprint."
        }
    }
    
    private func renderConfidence(tier: EvidenceTier) -> String {
        switch tier {
        case .S:
            return "Another application on this Mac uses this too, so it stays."
        case .A:
            return "It has a direct structural link to the application."
        case .B:
            return "It is highly probable this belongs to the application based on developer naming conventions."
        case .C:
            return "This is a heuristic match and may be shared or generic data."
        }
    }
    
    private func renderCapability(capability: Capability) -> String {
        switch capability {
        case .ok:
            return ""
        case .needsHelper:
            return "Removing it requires administrator privileges."
        case .needsFullDiskAccess:
            return "Removing it requires Full Disk Access."
        case .refusedByOS:
            return "The operating system prevents its removal."
        }
    }
}
