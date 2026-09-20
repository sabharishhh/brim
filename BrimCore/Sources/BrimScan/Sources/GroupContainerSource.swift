import Foundation
import BrimCore

public struct GroupContainerSource: EvidenceSource {
    public init() {}
    
    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        var results = [Evidence]()
        let fm = FileManager.default
        
        let containerDirs = [
            root.url(for: .userLibrary).appendingPathComponent("Group Containers"),
            root.url(for: .systemLibrary).appendingPathComponent("Group Containers")
        ]
        
        for group in identity.groupContainers {
            for dir in containerDirs {
                let url = dir.appendingPathComponent(group)
                if fm.fileExists(atPath: url.path) {
                    results.append(Evidence(
                        url: url,
                        tier: .A,
                        mechanism: "GroupContainerSource",
                        humanSentence: "Group container explicitly declared in application entitlements"
                    ))
                }
            }
        }
        
        return results
    }
}
