import BrimCore
import Foundation

/// Group containers sitting under this application's team identifier.
///
/// **A team identifier names a vendor, not an application**, and this source
/// used to forget that. It rated every `TEAMID.*` folder Tier B, which means
/// ticked for removal by default, on the strength of a string that Microsoft
/// puts on Word, Teams, OneDrive and Visual Studio Code alike.
///
/// It went unnoticed because it never ran. `IdentityResolver` asked macOS for
/// the wrong class of signing information, so `Identity.teamID` was nil for
/// every application on the machine and this source returned an empty array
/// every time. Fixing that one flag turned a dormant over-claim into a live
/// one: on the Mac this was measured on, uninstalling Visual Studio Code
/// offered up `UBF8T346G9.com.microsoft.teams` and
/// `UBF8T346G9.com.microsoft.oneauth`, pre-selected, with Microsoft Teams
/// installed. That is somebody else's data and the shared sign-in state for
/// every Microsoft application on the Mac.
///
/// So the evidence says what it actually is.
///
/// - A group an application **declares** in its entitlements is proof, and
///   `GroupContainerSource` reports those at Tier A. This source never does.
/// - A folder matched on the team identifier alone, while another
///   application from the same vendor is installed, is **Tier S**: something
///   else on this Mac claims it, so it leaves the selection and cannot
///   re-enter it.
/// - Anything else matched on the team identifier alone is **Tier C**. It is
///   shown, it can be ticked by hand, and Brim will not tick it for anybody.
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

        // Only now is it worth asking who else is on this Mac, because the
        // answer costs a directory walk and most applications match nothing
        // here at all.
        let siblingScan = await Self.otherApplicationFindings(sharing: teamID, besides: identity, in: root)
        let siblings = siblingScan.identities
        completeness = completeness.merging(siblingScan.completeness)

        let evidence = candidates.map { url in
            let name = url.lastPathComponent
            let claimant = siblings.first(where: { $0.groupContainers.contains(name) })
                ?? siblings.first
            if let claimant {
                return Evidence(
                    url: url,
                    tier: .S,
                    mechanism: "TeamIDSource",
                    humanSentence: "Shared with \(claimant.name), which is still installed. A "
                        + "team identifier belongs to the developer, not to one application."
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
        return EvidenceFindings(evidence: evidence, completeness: completeness)
    }

    /// Other installed applications signed by the same team.
    ///
    /// Top level only, and both Applications folders. A deep walk finds
    /// helpers nested inside bundles, which are not separate applications
    /// and would veto their own parent.
    static func otherApplicationFindings(
        sharing teamID: String, besides identity: Identity, in root: FileSystemRoot
    ) async -> (identities: [Identity], completeness: ScanCompleteness) {
        let directories = [
            root.url(for: .applications),
            root.url(for: .userLibrary).deletingLastPathComponent()
                .appendingPathComponent("Applications")
        ]
        let resolver = IdentityResolver(root: root)
        var found: [Identity] = []
        var unreadable: [String] = []
        for directory in directories {
            let names: [String]
            switch DirectoryEntries.read(directory) {
            case .absent:
                continue
            case .refused:
                unreadable.append(directory.path)
                continue
            case let .listed(listed):
                names = listed
            }
            for name in names where name.hasSuffix(".app") {
                let bundle = directory.appendingPathComponent(name)
                let other = await resolver.resolve(bundleURL: bundle)
                guard other.teamID == teamID else { continue }
                guard other.bundleID != identity.bundleID else { continue }
                found.append(other)
            }
        }
        return (found, ScanCompleteness(unreadable: unreadable))
    }
}
