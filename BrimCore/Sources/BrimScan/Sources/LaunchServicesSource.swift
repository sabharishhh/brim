import Foundation
#if canImport(AppKit)
import AppKit
#endif
import BrimCore

public struct LaunchServicesSource: EvidenceSource {
    public init() {}
    
    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        guard let bundleID = identity.bundleID else { return [] }
        var results = [Evidence]()
        
        #if canImport(AppKit)
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            // Verify it belongs to our root (relevant for tests mostly)
            if appURL.path.hasPrefix(root.rootURL.path) {
                results.append(Evidence(
                    url: appURL,
                    tier: .A,
                    mechanism: "LaunchServicesSource",
                    humanSentence: "Application registered with macOS Launch Services"
                ))
            }
        }
        #endif
        
        return results
    }
}
