import BrimCore
import Foundation

public struct BundleIdentifierStateSource: EvidenceSource {
    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        var results = [Evidence]()
        let fm = FileManager.default

        for bundleID in identity.searchBundleIdentifiers {
            let paths: [(String, String)] = [
                ("HTTPStorages/\(bundleID)", "HTTP storage cache"),
                ("Saved Application State/\(bundleID).savedState", "Saved application state"),
                ("Application Scripts/\(bundleID)", "Application scripts directory"),
                ("WebKit/\(bundleID)", "WebKit cache and local storage"),
                ("Caches/\(bundleID)", "Application cache"),
                ("Logs/\(bundleID)", "Application logs")
            ]

            for library in [root.url(for: .systemLibrary), root.url(for: .userLibrary)] {
                for (relative, desc) in paths {
                    let url = library.appendingPathComponent(relative)
                    guard fm.fileExists(atPath: url.path) else { continue }
                    results.append(Evidence(
                        url: url,
                        tier: bundleID == identity.bundleID ? .B : .C,
                        mechanism: "BundleIdentifierStateSource",
                        humanSentence: desc
                    ))
                }
            }
        }

        return results
    }
}
