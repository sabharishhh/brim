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
                //
                // Named after means the identifier itself, or the identifier
                // followed by a dot. It used to be any label that merely
                // started with it, with nothing required after, and on the
                // Mac this was found on that made the News application
                // (`com.apple.news`) the owner of `com.apple.newsyslog`, the
                // system's log rotation daemon, and Clock the owner of
                // `com.apple.clocksyncd`. Tier A is ticked by default and a
                // ticked job is unloaded, so for anybody else's applications
                // `com.example.app` would take `com.example.applet` with it.
                // The rest of the codebase already draws the line here:
                // `LocationInventorySource` matches the identifier and a dot.
                //
                // Kept strict on purpose. A developer who names a helper
                // `com.example.appHelper` or `com.example.app-helper` loses
                // the label match, and nothing is lost for it: a helper that
                // runs from inside the bundle is proven by the program path
                // below, and a privileged helper blessed with `SMJobBless`
                // carries its own bundle identifier as its label, which is
                // conventionally the application's with a dot. What the
                // boundary costs on this Mac is Apple's own agents named
                // without one, `com.apple.SafariLaunchAgent` and `newsd`
                // among them, for applications Brim cannot remove anyway.
                var proven = false
                if let label = plistIdentity.launchdLabel,
                   label == targetBundleID || label.hasPrefix(targetBundleID + ".") {
                    proven = true
                }
                // The program running from inside this application's bundle
                // is proof whatever the label says, and it is what keeps the
                // strict label boundary above from costing recall. So it has
                // to look in every bundle this application could be, which
                // `AppBundleSource` has always taken to include the
                // Applications folder inside the home folder; it used to
                // look only in `/Applications`, so a per-user install's
                // helper went unproven. And inside means the bundle followed
                // by a slash: this compared with a bare `hasPrefix`, so a
                // program in `App.apple.app` proved a job belonged to `App`.
                if !proven, let program = plistIdentity.launchdProgramPath {
                    proven = SymlinkIntoBundleSource.bundleLocations(for: identity, in: root)
                        .contains { program.hasPrefix($0.path + "/") }
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
