import BrimCore
import Foundation

/// Group containers under this application's team identifier. A team names
/// a vendor, not an application, so:
/// - a group the app declares in its entitlements is proof, reported by
///   `GroupContainerSource` at Tier A, never here;
/// - a folder matched on the team alone while another app from the vendor is
///   installed is Tier S;
/// - anything else matched on the team alone is Tier C: shown, tickable by
///   hand, never ticked by Brim.
public struct TeamIDSource: EvidenceSource {
    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        await scan(for: identity, in: root).evidence
    }

    public func scan(for identity: Identity, in root: FileSystemRoot) async -> EvidenceFindings {
        guard let teamID = identity.teamID else { return EvidenceFindings(evidence: []) }

        let containerDirs = [
            root.url(for: .userLibrary).appendingPathComponent("Group Containers"),
            root.url(for: .systemLibrary).appendingPathComponent("Group Containers")
        ]

        var completeness = ScanCompleteness.complete
        var candidates: [URL] = []
        for dir in containerDirs {
            switch DirectoryEntries.read(dir) {
            case .absent:
                break
            case .refused:
                completeness = completeness.merging(ScanCompleteness(unreadable: [dir.path]))
            case let .listed(names):
                for name in names where name == teamID || name.hasPrefix("\(teamID).") {
                    candidates.append(dir.appendingPathComponent(name))
                }
            }
        }
        guard !candidates.isEmpty else {
            return EvidenceFindings(evidence: [], completeness: completeness)
        }

        // Only now is it worth asking who else is on this Mac, because that costs a
        // walk and most apps match nothing here.
        let siblingScan = await Self.otherApplicationFindings(sharing: teamID, besides: identity, in: root)
        let siblings = siblingScan.identities
        completeness = completeness.merging(siblingScan.completeness)

        let evidence = candidates.compactMap { url in
            Self.evidence(for: url, identity: identity, siblings: siblings)
        }
        return EvidenceFindings(evidence: evidence, completeness: completeness)
    }

    private static func evidence(for url: URL, identity: Identity, siblings: [Identity]) -> Evidence? {
        let name = url.lastPathComponent
        // Another app declaring the group is a claim; one merely signed by the same
        // vendor is not.
        if let claimant = siblings.first(where: { $0.groupContainers.contains(name) }) {
            return Evidence(
                url: url,
                tier: .S,
                mechanism: "TeamIDSource",
                humanSentence: "Shared with \(claimant.name), which is still installed and "
                    + "declares this group."
            )
        }
        // Declared by this application alone: `GroupContainerSource`'s proof, which
        // an S here would outweigh.
        if identity.searchGroupContainers.contains(name) {
            return nil
        }
        if let sibling = siblings.first {
            return Evidence(
                url: url,
                tier: .S,
                mechanism: "TeamIDSource",
                humanSentence: "Nobody declares it, and \(sibling.name) is from the same "
                    + "developer. A team identifier belongs to the developer, not to one application."
            )
        }
        return Evidence(
            url: url,
            tier: .C,
            mechanism: "TeamIDSource",
            humanSentence: "Sits under this developer's team identifier. The application "
                + "does not declare it, so Brim will not tick it for you."
        )
    }

    // Other installed applications signed by the same team.
    //
    // The shared inventory stops at application bundles, so embedded
    // helpers cannot veto their own parent and vendor folders are included.

    static func otherApplicationFindings(
        sharing teamID: String, besides identity: Identity, in root: FileSystemRoot
    ) async -> (identities: [Identity], completeness: ScanCompleteness) {
        let inventory = await Task.detached { InstalledBundleInventory.read(in: root) }.value
        let resolver = IdentityResolver(root: root)
        var found: [Identity] = []
        for bundle in inventory.bundles {
            let other = await resolver.resolve(bundleURL: bundle)
            guard other.teamID == teamID else { continue }
            guard other.bundleID != identity.bundleID else { continue }
            found.append(other)
        }
        return (found, inventory.completeness)
    }
}
