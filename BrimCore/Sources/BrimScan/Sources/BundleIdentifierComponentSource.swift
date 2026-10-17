import BrimCore
import Foundation

/// Paths that match the exact bundle identifier, or a name the application
/// answers to. Names are Tier C suggestions; only an identifier match
/// reaches Tier B.
public struct BundleIdentifierComponentSource: EvidenceSource {
    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        var results = [Evidence]()
        let fm = FileManager.default

        // 1. Name matches, on every name the bundle answers to: Visual Studio Code
        // names its settings folder "Code".
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
        for bundleID in identity.searchBundleIdentifiers {
            let paths = [
                root.url(for: .userPreferences).appendingPathComponent("\(bundleID).plist"),
                root.url(for: .systemLibrary).appendingPathComponent("Preferences/\(bundleID).plist"),
                root.url(for: .userApplicationSupport).appendingPathComponent(bundleID),
                root.url(for: .systemLibrary).appendingPathComponent("Application Support/\(bundleID)")
            ]

            for url in paths where fm.fileExists(atPath: url.path) {
                let isPref = url.path.contains("Preferences")
                let match = Evidence(
                    url: url,
                    tier: bundleID == identity.bundleID ? .B : .C,
                    mechanism: "BundleIdentifierComponentSource",
                    humanSentence: isPref
                        ? "Preferences keyed to the bundle identifier"
                        : "Application Support keyed to the bundle identifier"
                )
                if let previous = results.firstIndex(where: { $0.url == url }) {
                    if bundleID == identity.bundleID {
                        results[previous] = match
                    }
                } else {
                    results.append(match)
                }
            }
        }

        return results
    }
}
