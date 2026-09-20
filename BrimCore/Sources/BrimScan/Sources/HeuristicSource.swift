import Foundation
import BrimCore

public struct HeuristicSource: EvidenceSource {
    public init() {}
    
    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        var evidence = [Evidence]()
        
        let domains = [
            root.url(for: .userApplicationSupport),
            root.url(for: .userLibrary).appendingPathComponent("Caches"),
            root.url(for: .userPreferences)
        ]
        
        let fm = FileManager.default
        let nameSegments = identity.name.lowercased().split(separator: " ").map { String($0) }
        let bundleSegments = identity.bundleID?.lowercased().split(separator: ".").map { String($0) } ?? []
        
        for domainURL in domains {
            guard let contents = try? fm.contentsOfDirectory(at: domainURL, includingPropertiesForKeys: nil) else { continue }
            
            for itemURL in contents {
                let itemName = itemURL.lastPathComponent.lowercased()
                
                // Skip exact bundle ID matches since those are handled by exact match sources (Tier A/B)
                if let bundleID = identity.bundleID, itemName == bundleID.lowercased() {
                    continue
                }
                
                var matches = false
                
                // Heuristic 1: Folder contains the exact app name
                if itemName.contains(identity.name.lowercased().replacingOccurrences(of: " ", with: "")) {
                    matches = true
                }
                
                // Heuristic 2: Folder contains a significant segment of the bundle ID (like vendor name)
                if !matches, bundleSegments.count >= 2 {
                    let vendor = bundleSegments[1] // com.vendor.app
                    if vendor.count > 3 && itemName.contains(vendor) {
                        matches = true
                    }
                }
                
                if matches {
                    evidence.append(Evidence(
                        url: itemURL,
                        tier: .C,
                        mechanism: "HeuristicSource",
                        humanSentence: "Matches application name or vendor footprint heuristics."
                    ))
                }
            }
        }
        
        return evidence
    }
}
