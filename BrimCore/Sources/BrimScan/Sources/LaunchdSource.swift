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
        
        for searchDir in paths {
            guard let contents = try? fm.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: nil) else { continue }
            for plistURL in contents {
                guard plistURL.pathExtension == "plist" else { continue }
                
                // Parse it using IdentityResolver
                let plistIdentity = await identityResolver.resolve(launchdPlistURL: plistURL)
                
                var matches = false
                if let label = plistIdentity.launchdLabel {
                    if label.starts(with: targetBundleID) {
                        matches = true
                    } else if let teamID = identity.teamID, label.starts(with: teamID) {
                        matches = true
                    }
                }
                
                if !matches, let program = plistIdentity.launchdProgramPath {
                    if let appBundlePath = root.url(for: .applications).appendingPathComponent("\(identity.name).app").path as String?,
                       program.hasPrefix(appBundlePath) {
                        matches = true
                    }
                }
                
                if matches {
                    results.append(Evidence(
                        url: plistURL,
                        tier: .A,
                        mechanism: "LaunchdSource",
                        humanSentence: "Background service registration"
                    ))
                }
            }
        }
        
        return results
    }
}
