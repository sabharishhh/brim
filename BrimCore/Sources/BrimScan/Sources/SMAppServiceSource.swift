import Foundation
import BrimCore

public struct SMAppServiceSource: EvidenceSource {
    public init() {}
    
    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        var results = [Evidence]()
        let fm = FileManager.default
        
        // We need to look inside the primary app bundle for this identity.
        // We will guess the bundle location if it's not provided, but mostly
        // this relies on AppBundleSource having found it.
        // For independence, we'll check standard locations.
        let name = identity.name
        let appPaths = [
            root.url(for: .applications).appendingPathComponent("\(name).app"),
            root.url(for: .userApplicationSupport).appendingPathComponent("\(name).app")
        ]
        
        for appURL in appPaths {
            guard fm.fileExists(atPath: appURL.path) else { continue }
            
            let lsDir = appURL.appendingPathComponent("Contents/Library/LaunchServices")
            if let contents = try? fm.contentsOfDirectory(at: lsDir, includingPropertiesForKeys: nil) {
                for fileURL in contents {
                    results.append(Evidence(
                        url: fileURL,
                        tier: .A,
                        mechanism: "SMAppServiceSource",
                        humanSentence: "Privileged helper tool bundled within the application"
                    ))
                }
            }
            
            let ldDir = appURL.appendingPathComponent("Contents/Library/LaunchDaemons")
            if let contents = try? fm.contentsOfDirectory(at: ldDir, includingPropertiesForKeys: nil) {
                for fileURL in contents {
                    results.append(Evidence(
                        url: fileURL,
                        tier: .A,
                        mechanism: "SMAppServiceSource",
                        humanSentence: "Background daemon bundled within the application"
                    ))
                }
            }
            
            let laDir = appURL.appendingPathComponent("Contents/Library/LaunchAgents")
            if let contents = try? fm.contentsOfDirectory(at: laDir, includingPropertiesForKeys: nil) {
                for fileURL in contents {
                    results.append(Evidence(
                        url: fileURL,
                        tier: .A,
                        mechanism: "SMAppServiceSource",
                        humanSentence: "Background agent bundled within the application"
                    ))
                }
            }
        }
        
        return results
    }
}
