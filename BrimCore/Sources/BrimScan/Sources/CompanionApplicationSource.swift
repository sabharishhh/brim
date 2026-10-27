import BrimCore
import Foundation

/// Standalone launchers and URL handlers whose declared executable links into
/// the selected application. No name, shared developer or install date can
/// establish this relationship on its own.
public struct CompanionApplicationSource: EvidenceSource {
    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        try await scan(for: identity, in: root).evidence
    }

    public func scan(for identity: Identity, in root: FileSystemRoot) async throws -> EvidenceFindings {
        let owners = SymlinkIntoBundleSource.verifiedBundleLocations(for: identity, in: root)
        guard !owners.isEmpty else { return EvidenceFindings(evidence: []) }
        let inventory = InstalledBundleInventory.read(in: root)
        let evidence = inventory.bundles.compactMap { bundle -> Evidence? in
            let linked = owners.contains { ApplicationBundle.runsInside(bundle, owner: $0, in: root) }
            guard linked, !owners.contains(where: { $0.standardizedFileURL == bundle.standardizedFileURL }) else {
                return nil
            }
            return Evidence(
                url: bundle, tier: .B, mechanism: "CompanionApplicationSource",
                humanSentence: "This companion application's executable is a link into \(identity.name). "
                    + "It cannot run once that application is removed."
            )
        }
        return EvidenceFindings(evidence: evidence, completeness: inventory.completeness)
    }
}
