import BrimCore
import Foundation

public struct LaunchdSource: EvidenceSource {
    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        await scan(for: identity, in: root).evidence
    }

    public func scan(for identity: Identity, in root: FileSystemRoot) async -> EvidenceFindings {
        var results = [Evidence]()
        var completeness = ScanCompleteness.complete

        let paths = [
            root.url(for: .systemLaunchDaemons),
            root.url(for: .systemLaunchAgents),
            root.url(for: .userLaunchAgents),
            root.rootURL.appendingPathComponent("System/Library/LaunchDaemons"),
            root.rootURL.appendingPathComponent("System/Library/LaunchAgents")
        ]

        // Find the bundle ID and Team ID
        guard let targetBundleID = identity.bundleID else {
            return EvidenceFindings(evidence: results)
        }

        // Other installed applications from the same developer, looked up
        // once and only if a job turns out to be matched on the team alone.
        var siblings: [Identity]?
        // Worked out once: `Identity` derives these on every read, and there are
        // hundreds of job files to test.
        let embeddedIDs = identity.searchBundleIdentifiers.filter { $0 != targetBundleID }
        let declaredLabels = Set(identity.capabilitySurface?.declarations
            .filter { $0.capability == .launchdJob }
            .map(\.value) ?? [])

        for searchDir in paths {
            let contents: [URL]
            switch DirectoryEntries.read(searchDir) {
            case .absent:
                continue
            case .refused:
                completeness = completeness.merging(ScanCompleteness(unreadable: [searchDir.path]))
                continue
            case let .listed(names):
                contents = names.map { searchDir.appendingPathComponent($0) }
            }
            for plistURL in contents {
                guard plistURL.pathExtension == "plist" else { continue }

                guard let plistIdentity = Self.readJob(at: plistURL) else {
                    completeness = completeness.merging(ScanCompleteness(unreadable: [plistURL.path]))
                    continue
                }

                // Proof the job is this application's: its label is the identifier or the
                // identifier and a dot, or its program lives inside the app's bundle. A
                // bare prefix made `com.apple.news` own `com.apple.newsyslog`, and a ticked
                // job is unloaded. Strict on purpose: a helper whose label misses still
                // proves itself through the program path below.
                var proven = plistIdentity.launchdLabel.map { label in
                    label == targetBundleID || label.hasPrefix(targetBundleID + ".")
                } ?? false
                let label = plistIdentity.launchdLabel
                let embeddedMatch = label.map { label in
                    embeddedIDs.contains { label == $0 || label.hasPrefix($0 + ".") }
                        || declaredLabels.contains(label)
                } ?? false
                if embeddedMatch {
                    proven = false
                }
                // The program running from inside this application's bundle proves the job
                // whatever the label says. Checked against every bundle location the app
                // could have, including `~/Applications`, and "inside" means the bundle
                // path followed by a slash.
                if !proven, let program = plistIdentity.launchdProgramPath {
                    proven = SymlinkIntoBundleSource.verifiedBundleLocations(for: identity, in: root)
                        .contains { program.hasPrefix($0.path + "/") }
                }

                if proven || embeddedMatch {
                    results.append(Evidence(
                        url: plistURL,
                        tier: proven ? .A : .C,
                        mechanism: "LaunchdSource",
                        humanSentence: proven
                            ? "Background service registration"
                            : "Job label matches an embedded component or declaration."
                    ))
                    continue
                }

                // A label starting with the team identifier names the developer, not
                // which of their apps the job serves. Vetoed while a sibling from the same
                // developer is installed, and shown but never ticked otherwise, as
                // `TeamIDSource` treats group containers.
                guard let teamID = identity.teamID,
                      let label = plistIdentity.launchdLabel,
                      label == teamID || label.hasPrefix(teamID + ".")
                else { continue }
                if siblings == nil {
                    let siblingScan = await TeamIDSource.otherApplicationFindings(
                        sharing: teamID, besides: identity, in: root
                    )
                    siblings = siblingScan.identities
                    completeness = completeness.merging(siblingScan.completeness)
                }
                if let claimant = siblings?.first {
                    results.append(Evidence(
                        url: plistURL,
                        tier: .S,
                        mechanism: "LaunchdSource",
                        humanSentence: "Registered by this developer, and \(claimant.name) from the "
                            + "same developer is still installed and may rely on it."
                    ))
                } else {
                    results.append(Evidence(
                        url: plistURL,
                        tier: .C,
                        mechanism: "LaunchdSource",
                        humanSentence: "Registered under this developer's team identifier. Nothing "
                            + "says it belongs to this application, so Brim will not tick it for you."
                    ))
                }
            }
        }

        return EvidenceFindings(evidence: results, completeness: completeness)
    }

    private static func readJob(at url: URL) -> Identity? {
        guard let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
              as? [String: Any] else { return nil }
        return Identity(name: url.deletingPathExtension().lastPathComponent,
                        launchdLabel: values["Label"] as? String,
                        launchdProgramPath: (values["Program"] as? String)
                            ?? (values["ProgramArguments"] as? [String])?.first)
    }
}
