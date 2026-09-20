import Foundation
import BrimCore

/// Resolves the application bundle itself by searching standard locations (Tier A).
public struct AppBundleSource: EvidenceSource {
    public init() {}
    
    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        var results = [Evidence]()
        let fm = FileManager.default
        let name = identity.name
        
        let paths = [
            root.url(for: .applications).appendingPathComponent("\(name).app"),
            root.url(for: .userLibrary).deletingLastPathComponent().appendingPathComponent("Applications/\(name).app")
        ]
        
        for url in paths {
            if fm.fileExists(atPath: url.path) {
                results.append(Evidence(
                    url: url,
                    tier: .A,
                    mechanism: "AppBundleSource",
                    humanSentence: "The application bundle itself"
                ))
            }
        }
        return results
    }
}
