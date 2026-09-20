import Foundation
import BrimCore

public struct TeamIDSource: EvidenceSource {
    public init() {}
    
    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        guard let teamID = identity.teamID else { return [] }
        var results = [Evidence]()
        let fm = FileManager.default
        
        let containerDirs = [
            root.url(for: .userLibrary).appendingPathComponent("Group Containers"),
            root.url(for: .systemLibrary).appendingPathComponent("Group Containers")
        ]
        
        for dir in containerDirs {
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { print("TeamIDSource: Failed to read \(dir.path)"); continue }
            for url in contents {
                let name = url.lastPathComponent
                if name == teamID || name.hasPrefix("\(teamID).") {
                    // Check if it was already explicitly declared (tier A) so we don't double count?
                    // Deduplication happens in EvidenceEngine, so it's fine to yield it.
                    results.append(Evidence(
                        url: url,
                        tier: .B,
                        mechanism: "TeamIDSource",
                        humanSentence: "Container keyed to the developer's Team ID"
                    ))
                }
            }
        }
        
        return results
    }
}
