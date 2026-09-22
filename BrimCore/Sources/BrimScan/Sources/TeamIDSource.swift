import Foundation
import os
import BrimCore

private let log = BrimLog.make("scan")

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
        guard let teamID = identity.teamID else { return [] }
        let fm = FileManager.default

        let containerDirs = [
            root.url(for: .userLibrary).appendingPathComponent("Group Containers"),
            root.url(for: .systemLibrary).appendingPathComponent("Group Containers")
        ]

        // **This should be a coverage gap, not a log line.** A Group
        // Containers folder Brim cannot read is the "did not look is not
        // nothing found" case exactly, and returning an empty array for it
        // is the kind of unmeasured zero `RegistrationCoverage` and
        // `ScanCompleteness` exist to prevent. It is a log line because
        // `EvidenceSource` has nowhere to put the answer: only
        // `LocationInventorySource` carries a `findings` method returning
        // `ScanCompleteness`, and widening the protocol touches every source.
        // Until that happens this reads as a clean result and is not one.
        var candidates: [URL] = []
        for dir in containerDirs {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else {
                log.debug("could not read \(dir.path)")
                continue
            }
            for url in contents {
                let name = url.lastPathComponent
                if name == teamID || name.hasPrefix("\(teamID).") { candidates.append(url) }
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Only now is it worth asking who else is on this Mac, because the
        // answer costs a directory walk and most applications match nothing
        // here at all.
        let siblings = await Self.otherApplications(sharing: teamID, besides: identity, in: root)

        return candidates.map { url in
            let name = url.lastPathComponent
            if let claimant = siblings.first(where: { $0.groupContainers.contains(name) })
                ?? siblings.first {
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
    }

    /// Other installed applications signed by the same team.
    ///
    /// Top level only, and both Applications folders. A deep walk finds
    /// helpers nested inside bundles, which are not separate applications
    /// and would veto their own parent.
    static func otherApplications(
        sharing teamID: String, besides identity: Identity, in root: FileSystemRoot
    ) async -> [Identity] {
        let fm = FileManager.default
        let directories = [
            root.url(for: .applications),
            root.url(for: .userLibrary).deletingLastPathComponent()
                .appendingPathComponent("Applications"),
        ]
        let resolver = IdentityResolver(root: root)
        var found: [Identity] = []
        for directory in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasSuffix(".app") {
                let bundle = directory.appendingPathComponent(name)
                let other = await resolver.resolve(bundleURL: bundle)
                guard other.teamID == teamID else { continue }
                guard other.bundleID != identity.bundleID else { continue }
                found.append(other)
            }
        }
        return found
    }
}
