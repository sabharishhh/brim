import Foundation
#if canImport(AppKit)
    import AppKit
#endif
import BrimCore

public struct LaunchServicesSource: EvidenceSource {
    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        var results = [Evidence]()

        #if canImport(AppKit)
            let ownPaths = SymlinkIntoBundleSource.verifiedBundleLocations(for: identity, in: root)
                .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        let boundary = root.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        for bundleID in identity.searchBundleIdentifiers {
            guard bundleID == identity.bundleID else { continue }
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                      Bundle(url: appURL)?.bundleIdentifier == bundleID else { continue }
                // Verify it belongs to our root (relevant for tests mostly)
                let path = appURL.resolvingSymlinksInPath().standardizedFileURL.path
                let inRoot = boundary == "/" || path == boundary || path.hasPrefix(boundary + "/")
            let isOwnBundle = ownPaths.contains(path)
                if inRoot, isOwnBundle {
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
