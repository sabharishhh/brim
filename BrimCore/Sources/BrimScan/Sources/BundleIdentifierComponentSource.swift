import Foundation
import BrimCore

/// Resolves paths that match the exact bundle identifier or bundle name (Tier B).
public struct BundleIdentifierComponentSource: EvidenceSource {
    public init() {}
    
    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        var results = [Evidence]()
        let fm = FileManager.default
        
        // 1. Bundle Name matches
        let name = identity.name
        let paths = [
                root.url(for: .applications).appendingPathComponent("\(name).app"),
                root.url(for: .applications).appendingPathComponent("\(name)"),
                root.url(for: .userApplicationSupport).appendingPathComponent("\(name).app"),
                root.url(for: .systemLibrary).appendingPathComponent("Application Support/\(name).app"),
                root.url(for: .userApplicationSupport).appendingPathComponent(name),
                root.url(for: .systemLibrary).appendingPathComponent("Application Support/\(name)")
            ]
            
            for url in paths {
                if fm.fileExists(atPath: url.path) && !results.contains(where: { $0.url == url }) {
                    results.append(Evidence(
                        url: url,
                        tier: .B,
                        mechanism: "BundleIdentifierComponentSource",
                        humanSentence: "Matches the application's bundle name"
                    ))
                }
        }
        
        // 2. Bundle ID matches
        if let bundleID = identity.bundleID {
            let paths = [
                root.url(for: .userPreferences).appendingPathComponent("\(bundleID).plist"),
                root.url(for: .systemLibrary).appendingPathComponent("Preferences/\(bundleID).plist"),
                root.url(for: .userApplicationSupport).appendingPathComponent(bundleID),
                root.url(for: .systemLibrary).appendingPathComponent("Application Support/\(bundleID)")
            ]
            
            for url in paths {
                if fm.fileExists(atPath: url.path) && !results.contains(where: { $0.url == url }) {
                    let isPref = url.path.contains("Preferences")
                    results.append(Evidence(
                        url: url,
                        tier: .B,
                        mechanism: "BundleIdentifierComponentSource",
                        humanSentence: isPref ? "Preferences keyed to the bundle identifier" : "Application Support keyed to the bundle identifier"
                    ))
                }
            }
        }
        
        return results
    }
}
