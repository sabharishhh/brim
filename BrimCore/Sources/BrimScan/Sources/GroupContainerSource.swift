import BrimCore
import Foundation

public struct GroupContainerSource: EvidenceSource {
    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        await scan(for: identity, in: root).evidence
    }

    public func scan(for identity: Identity, in root: FileSystemRoot) async -> EvidenceFindings {
        var results = [Evidence]()
        var unreadable: [String] = []
        let fm = FileManager.default

        let containerDirs = [
            root.url(for: .userLibrary).appendingPathComponent("Group Containers"),
            root.url(for: .systemLibrary).appendingPathComponent("Group Containers")
        ]

        if !identity.searchGroupContainers.isEmpty {
            let parents = containerDirs + [
                root.url(for: .userLibrary).appendingPathComponent("Application Scripts"),
                root.url(for: .systemLibrary).appendingPathComponent("Application Scripts")
            ]
            for parent in parents {
                if case .refused = DirectoryEntries.read(parent) {
                    unreadable.append(parent.path)
                }
            }
        }

        for group in identity.searchGroupContainers {
            for dir in containerDirs {
                let url = dir.appendingPathComponent(group)
                if fm.fileExists(atPath: url.path) {
                    results.append(Evidence(
                        url: url,
                        tier: .A,
                        mechanism: "GroupContainerSource",
                        humanSentence: "Group container explicitly declared in application entitlements"
                    ))
                }
            }
            for library in [root.url(for: .userLibrary), root.url(for: .systemLibrary)] {
                let scripts = library.appendingPathComponent("Application Scripts/\(group)")
                if fm.fileExists(atPath: scripts.path) {
                    results.append(Evidence(url: scripts, tier: .A,
                                            mechanism: "GroupContainerSource",
                                            humanSentence: "Application scripts for a declared group"))
                }
            }
        }

        return EvidenceFindings(evidence: results, completeness: ScanCompleteness(unreadable: unreadable))
    }
}
