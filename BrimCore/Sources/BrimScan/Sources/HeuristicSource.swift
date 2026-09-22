import Foundation
import BrimCore

/// Not wired into the engine.
///
/// `BrimService` builds `EvidenceEngine` from eleven sources and this is not
/// one of them, so nothing in the product has ever produced a piece of
/// `HeuristicSource` evidence. It survived the scope cleanup that removed
/// the duplicate finder and the BTM reset because, unlike those, it serves
/// the thing Brim is for: it is unfinished core work rather than a feature
/// that should not exist. Wire it or delete it; leaving it here unwired is
/// the one option that helps nobody.
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
                
                let identityNameKey = identity.name.lowercased().replacingOccurrences(of: " ", with: "")
                
                // Heuristic 1: Folder exactly matches the app name or contains it as a distinct word prefix
                if itemName == identityNameKey || itemName.hasPrefix(identityNameKey + ".") || itemName.hasPrefix(identityNameKey + "-") {
                    matches = true
                }
                
                // Heuristic 2: Folder contains a significant segment of the bundle ID (like vendor name)
                if !matches, bundleSegments.count >= 2 {
                    let vendor = bundleSegments[1] // com.vendor.app
                    if vendor.count > 3 && (itemName == vendor || itemName.hasPrefix(vendor + ".") || itemName.hasPrefix(vendor + "-")) {
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
