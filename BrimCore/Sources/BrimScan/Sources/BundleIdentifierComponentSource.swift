import BrimCore
import Foundation

/// Resolves paths that match the exact bundle identifier, or either of the
/// names the application answers to.
///
/// Names are suggestions at Tier C. Only an identifier match reaches Tier B.
public struct BundleIdentifierComponentSource: EvidenceSource {
    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        var results = [Evidence]()
        let fm = FileManager.default

        // 1. Name matches, on both names the bundle answers to. Visual
        // Studio Code is "Visual Studio Code" as a file and "Code" to
        // itself, and it is the second one that names the folder holding
        // its settings, history and extensions.
        for name in identity.searchNames {
            let paths = [
                root.url(for: .applications).appendingPathComponent("\(name)"),
                root.url(for: .userApplicationSupport).appendingPathComponent("\(name).app"),
                root.url(for: .systemLibrary).appendingPathComponent("Application Support/\(name).app"),
                root.url(for: .userApplicationSupport).appendingPathComponent(name),
                root.url(for: .systemLibrary).appendingPathComponent("Application Support/\(name)")
            ]

            for url in paths {
                if fm.fileExists(atPath: url.path), !results.contains(where: { $0.url == url }) {
                    results.append(Evidence(
                        url: url,
                        tier: .C,
                        mechanism: "BundleIdentifierComponentSource",
                        humanSentence: "Name matches the application."
                    ))
                }
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
                if fm.fileExists(atPath: url.path), !results.contains(where: { $0.url == url }) {
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
