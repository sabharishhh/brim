import Foundation
import BrimCore

/// Resolves sandbox containers and application groups (Tier A).
public struct SandboxContainerSource: EvidenceSource {
    public init() {}
    
    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        var results = [Evidence]()
        
        guard let bundleID = identity.bundleID else {
            return results
        }
        
        let fm = FileManager.default
        
        // 1. Sandbox container
        let userContainer = root.url(for: .userContainers).appendingPathComponent(bundleID)
        let sysContainer = root.url(for: .systemLibrary).appendingPathComponent("Containers/\(bundleID)")
        
        for url in [userContainer, sysContainer] {
            if fm.fileExists(atPath: url.path) {
                results.append(Evidence(
                    url: url,
                    tier: .A,
                    mechanism: "SandboxContainerSource",
                    humanSentence: "Sandbox container keyed to this bundle identifier"
                ))
            }
        }
        
        // 2. Group containers
        let userGroupDir = root.url(for: .userGroupContainers)
        let sysGroupDir = root.url(for: .systemLibrary).appendingPathComponent("Group Containers")
        
        let groupsToCheck = !identity.groupContainers.isEmpty ? identity.groupContainers : ["group.\(bundleID)"]
        
        for group in groupsToCheck {
            for dir in [userGroupDir, sysGroupDir] {
                let groupURL = dir.appendingPathComponent(group)
                if fm.fileExists(atPath: groupURL.path) && !results.contains(where: { $0.url == groupURL }) {
                    results.append(Evidence(
                        url: groupURL,
                        tier: .A,
                        mechanism: "SandboxContainerSource",
                        humanSentence: "Group container declared in application entitlements"
                    ))
                }
            }
        }
        
        return results
    }
}
