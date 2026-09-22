import Foundation
import BrimCore

/// Resolves paths that match the exact bundle identifier, or either of the
/// names the application answers to.
///
/// An identifier is a reverse-DNS string nobody else uses, so a folder named
/// one is Tier B. A human name is not, and this source used to call a name
/// match Tier B as well, which meant a folder was ticked for removal by
/// default on the strength of sharing a word with an application. The
/// inventory has said "an identifier match is Tier B, a name match is Tier C"
/// since it was written; this is the one place that disagreed, and it
/// disagreed in the direction that removes things.
public struct BundleIdentifierComponentSource: EvidenceSource {
    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        var results = [Evidence]()
        let fm = FileManager.default

        // 1. Name matches, on both names the bundle answers to. Visual
        // Studio Code is "Visual Studio Code" as a file and "Code" to
        // itself, and it is the second one that names the folder holding
        // 143 MB of its settings, history and extensions.
        for name in identity.searchNames {
            let paths = [
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
                        tier: .C,
                        mechanism: "BundleIdentifierComponentSource",
                        humanSentence: "Named after the application rather than its identifier, "
                            + "so Brim will not tick it for you."
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
