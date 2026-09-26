import BrimCore
import Foundation

/// Resolves the application bundle itself by searching standard locations (Tier A).
public struct AppBundleSource: EvidenceSource {
    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        var results = [Evidence]()
        let fm = FileManager.default

        let paths = SymlinkIntoBundleSource.bundleLocations(for: identity, in: root)

        for url in paths {
            if fm.fileExists(atPath: url.path) {
                results.append(Evidence(
                    url: url,
                    tier: Bundle(url: url)?.bundleIdentifier == identity.bundleID
                        && identity.bundleID != nil ? .A : .C,
                    mechanism: "AppBundleSource",
                    humanSentence: "The application bundle itself"
                ))
            }
        }
        return results
    }
}
