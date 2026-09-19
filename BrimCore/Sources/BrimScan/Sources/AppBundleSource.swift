import Foundation
import BrimCore

/// Resolves the application bundle itself (Tier A).
public struct AppBundleSource: EvidenceSource {
    public let bundleURL: URL
    
    public init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }
    
    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        return [
            Evidence(
                url: bundleURL,
                tier: .A,
                mechanism: "AppBundleSource",
                humanSentence: "The application bundle itself"
            )
        ]
    }
}
