import Foundation
import os
import BrimCore

private let log = BrimLog.make("scan")

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
        
        // **This should be a coverage gap, not a log line.** A Group
        // Containers folder Brim cannot read is the "did not look is not
        // nothing found" case exactly, and returning an empty array for it
        // is the kind of unmeasured zero `RegistrationCoverage` and
        // `ScanCompleteness` exist to prevent. It is a log line because
        // `EvidenceSource` has nowhere to put the answer: only
        // `LocationInventorySource` carries a `findings` method returning
        // `ScanCompleteness`, and widening the protocol touches every source.
        // Until that happens this reads as a clean result and is not one.
        for dir in containerDirs {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else {
                log.debug("could not read \(dir.path)")
                continue
            }
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
