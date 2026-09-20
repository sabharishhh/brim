import Foundation
import BrimCore

public struct BundleIdentifierStateSource: EvidenceSource {
    public init() {}
    
    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        guard let bundleID = identity.bundleID else { return [] }
        var results = [Evidence]()
        let fm = FileManager.default
        
        let paths: [(URL, String)] = [
            (root.url(for: .systemLibrary).appendingPathComponent("HTTPStorages/\(bundleID)"), "HTTP storage cache"),
            (root.url(for: .systemLibrary).appendingPathComponent("Saved Application State/\(bundleID).savedState"), "Saved application state"),
            (root.url(for: .systemLibrary).appendingPathComponent("Application Scripts/\(bundleID)"), "Application scripts directory"),
            (root.url(for: .systemLibrary).appendingPathComponent("WebKit/\(bundleID)"), "WebKit cache and local storage"),
            (root.url(for: .systemLibrary).appendingPathComponent("Caches/\(bundleID)"), "Application cache"),
            (root.url(for: .systemLibrary).appendingPathComponent("Logs/\(bundleID)"), "Application logs"),
            (root.url(for: .userLibrary).appendingPathComponent("HTTPStorages/\(bundleID)"), "HTTP storage cache"),
            (root.url(for: .userLibrary).appendingPathComponent("Saved Application State/\(bundleID).savedState"), "Saved application state"),
            (root.url(for: .userLibrary).appendingPathComponent("Application Scripts/\(bundleID)"), "Application scripts directory"),
            (root.url(for: .userLibrary).appendingPathComponent("WebKit/\(bundleID)"), "WebKit cache and local storage"),
            (root.url(for: .userLibrary).appendingPathComponent("Caches/\(bundleID)"), "Application cache"),
            (root.url(for: .userLibrary).appendingPathComponent("Logs/\(bundleID)"), "Application logs")
        ]
        
        for (url, desc) in paths {
            if fm.fileExists(atPath: url.path) {
                results.append(Evidence(
                    url: url,
                    tier: .B,
                    mechanism: "BundleIdentifierStateSource",
                    humanSentence: desc
                ))
            }
        }
        
        return results
    }
}
