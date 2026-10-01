import BrimCore
import Foundation

/// Finds sandbox and declared group containers.
public struct SandboxContainerSource: EvidenceSource {
    private let budget: @Sendable () -> ScanBudget

    public init(budget: @escaping @Sendable () -> ScanBudget = { ScanBudget() }) {
        self.budget = budget
    }

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        await scan(for: identity, in: root).evidence
    }

    public func scan(for identity: Identity, in root: FileSystemRoot) async -> EvidenceFindings {
        let containerDirs = [
            root.url(for: .userContainers),
            root.url(for: .systemLibrary).appendingPathComponent("Containers")
        ]
        let groupDirs = [
            root.url(for: .userGroupContainers),
            root.url(for: .systemLibrary).appendingPathComponent("Group Containers")
        ]
        var search = DirectorySearch(budget: budget())
        let containers = containerEvidence(for: identity, in: containerDirs, search: &search)
        for directory in groupDirs {
            _ = search.entries(directory)
        }
        return EvidenceFindings(evidence: containers.evidence + groupEvidence(for: identity, in: groupDirs),
                                completeness: search.completeness.merging(containers.completeness))
    }

    private func containerEvidence(
        for identity: Identity, in directories: [URL], search: inout DirectorySearch
    ) -> EvidenceFindings {
        let subject = LocationInventory.Subject(identity)
        var evidence: [Evidence] = []
        var completeness = ScanCompleteness.complete
        for directory in directories {
            for name in search.entries(directory) where !name.hasPrefix(".") {
                let url = directory.appendingPathComponent(name)
                guard search.canContinue(at: url) else { break }
                let ownership = ContainerOwnershipReader.read(at: url, budget: search.budget)
                completeness = completeness.merging(ownership.completeness)
                guard ownership.identifiers.contains(where: { subject.longestIdentifier(prefixing: $0) != nil })
                else { continue }
                let identifier = ownership.identifier
                let owned = identifier.map(identity.ownsIdentifier) ?? false
                evidence.append(Evidence(
                    url: url, tier: ownership.uncertainty == nil && owned ? .A : .C,
                    mechanism: "SandboxContainerSource",
                    humanSentence: ownership.uncertainty ?? (name == identifier
                        ? "Sandbox container keyed to this bundle identifier"
                        : "Container metadata names \(identifier ?? name).")
                ))
            }
        }
        return EvidenceFindings(evidence: evidence, completeness: completeness)
    }

    private func groupEvidence(for identity: Identity, in directories: [URL]) -> [Evidence] {
        if !identity.searchGroupContainers.isEmpty {
            return identity.searchGroupContainers.flatMap { group in
                directories.compactMap { directory in
                    let url = directory.appendingPathComponent(group)
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return Evidence(url: url, tier: .A,
                                    mechanism: "SandboxContainerSource",
                                    humanSentence: "Group container declared in application entitlements")
                }
            }
        }
        return identity.searchBundleIdentifiers.flatMap { identifier in
            directories.compactMap { directory in
                let url = directory.appendingPathComponent("group.\(identifier)")
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return Evidence(url: url, tier: .C,
                                mechanism: "SandboxContainerSource",
                                humanSentence: "Group name matches the application.")
            }
        }
    }
}
