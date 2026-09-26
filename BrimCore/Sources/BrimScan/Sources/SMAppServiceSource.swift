import BrimCore
import Foundation

public struct SMAppServiceSource: EvidenceSource {
    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        await scan(for: identity, in: root).evidence
    }

    public func scan(for identity: Identity, in root: FileSystemRoot) async -> EvidenceFindings {
        var results = [Evidence]()
        var completeness = ScanCompleteness.complete
        let folders = [
            ("Contents/Library/LaunchServices", "Privileged helper tool bundled within the application"),
            ("Contents/Library/LaunchDaemons", "Background daemon bundled within the application"),
            ("Contents/Library/LaunchAgents", "Background agent bundled within the application")
        ]
        for appURL in SymlinkIntoBundleSource.verifiedBundleLocations(for: identity, in: root) {
            for (relative, description) in folders {
                let found = Self.bundledEvidence(in: appURL.appendingPathComponent(relative),
                                                 description: description)
                results.append(contentsOf: found.evidence)
                completeness = completeness.merging(found.completeness)
            }
        }
        return EvidenceFindings(evidence: results, completeness: completeness)
    }

    private static func bundledEvidence(in directory: URL, description: String) -> EvidenceFindings {
        switch DirectoryEntries.read(directory) {
        case .absent:
            EvidenceFindings(evidence: [])
        case .refused:
            EvidenceFindings(evidence: [], completeness: ScanCompleteness(unreadable: [directory.path]))
        case let .listed(names):
            EvidenceFindings(evidence: names.map { name in
                Evidence(url: directory.appendingPathComponent(name), tier: .A,
                         mechanism: "SMAppServiceSource", humanSentence: description)
            })
        }
    }
}
