import Foundation
import BrimCore

public struct LaunchdSource: EvidenceSource {
    public init() {}
    
    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        var results = [Evidence]()
        let fm = FileManager.default
        
        let paths = [
            root.url(for: .systemLaunchDaemons),
            root.url(for: .systemLaunchAgents),
            root.url(for: .userLaunchAgents),
            root.rootURL.appendingPathComponent("System/Library/LaunchDaemons"),
            root.rootURL.appendingPathComponent("System/Library/LaunchAgents")
        ]
        
        // Find the bundle ID and Team ID
        guard let targetBundleID = identity.bundleID else {
            return results
        }
        
        let identityResolver = IdentityResolver(root: root)
        // Other installed applications from the same developer, looked up
        // once and only if a job turns out to be matched on the team alone.
        var siblings: [Identity]?

        for searchDir in paths {
            guard let contents = try? fm.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: nil) else { continue }
            for plistURL in contents {
                guard plistURL.pathExtension == "plist" else { continue }
                
                // Parse it using IdentityResolver
                let plistIdentity = await identityResolver.resolve(launchdPlistURL: plistURL)

                // Proof that the job is this application's: its label is
                // named after the application, or the program it runs lives
                // inside the application's bundle.
                var proven = false
                if let label = plistIdentity.launchdLabel, label.starts(with: targetBundleID) {
                    proven = true
                }
                if !proven, let program = plistIdentity.launchdProgramPath {
                    if let appBundlePath = root.url(for: .applications).appendingPathComponent("\(identity.name).app").path as String?,
                       program.hasPrefix(appBundlePath) {
                        proven = true
                    }
                }

                if proven {
                    results.append(Evidence(
                        url: plistURL,
                        tier: .A,
                        mechanism: "LaunchdSource",
                        humanSentence: "Background service registration"
                    ))
                    continue
                }

                // A label that starts with the team identifier says which
                // developer registered the job and nothing about which of
                // their applications it serves. This used to be Tier A,
                // which means unloaded by default along with whichever of a
                // developer's applications was being removed. It never ran,
                // because the team identifier never resolved; fixing that
                // made it reachable. Handled the way `TeamIDSource` handles
                // a group container matched the same way: vetoed while a
                // sibling from the same developer is installed, and shown
                // but never ticked otherwise.
                guard let teamID = identity.teamID,
                      let label = plistIdentity.launchdLabel,
                      label == teamID || label.hasPrefix(teamID + ".")
                else { continue }
                if siblings == nil {
                    siblings = await TeamIDSource.otherApplications(
                        sharing: teamID, besides: identity, in: root
                    )
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
        
        return results
    }
}
