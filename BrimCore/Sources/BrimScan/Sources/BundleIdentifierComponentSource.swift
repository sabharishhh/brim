import Foundation
import BrimCore

/// Resolves paths that match the exact bundle identifier, or either of the
/// names the application answers to.
///
/// **Two names, rated differently, and the difference is deliberate.**
///
/// A folder named exactly after the application's own file name keeps the
/// Tier B it has always had here. That contradicts the inventory's rule
/// that a name match is Tier C, and it is kept anyway because of what Tier C
/// means in the uninstall sheet today: the sheet shows what is ticked and
/// nothing else, so a Tier C row there cannot be ticked by hand at all.
/// Demoting this match was tried, and it was caught only by opening the
/// sheet: uninstalling Claude would have stopped removing its 11 GB
/// `Application Support/Claude`, Figma its 1.1 GB, with no way for the
/// person to put either back. When the sheet can offer an unticked row,
/// this can follow the rule.
///
/// The `CFBundleName`, where it differs from the file name, is Tier C: shown,
/// never ticked. That is the name that can be as short as "Code", which is
/// exactly the string that makes name matching dangerous, and the plan that
/// added it says it must not be pre-selected whatever produced it.
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
            let isFileName = name == identity.name
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
                        tier: isFileName ? .B : .C,
                        mechanism: "BundleIdentifierComponentSource",
                        humanSentence: isFileName
                            ? "Named after the application."
                            : "Named after the name the application gives itself rather than "
                                + "its identifier, so Brim will not tick it for you."
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
