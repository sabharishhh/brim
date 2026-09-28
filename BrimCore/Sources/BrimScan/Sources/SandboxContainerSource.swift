import BrimCore
import Foundation

/// Finds sandbox and declared group containers.
public struct SandboxContainerSource: EvidenceSource {
    public init() {}

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
        let unreadable = (containerDirs + groupDirs)
            .filter { DirectoryEntries.read($0).isRefused }
            .map(\.path)
        let evidence = containerEvidence(for: identity, in: containerDirs)
            + groupEvidence(for: identity, in: groupDirs)
        return EvidenceFindings(evidence: evidence,
                                completeness: ScanCompleteness(unreadable: unreadable))
    }

    private func containerEvidence(for identity: Identity, in directories: [URL]) -> [Evidence] {
        identity.searchBundleIdentifiers.flatMap { identifier in
            directories.compactMap { directory in
                let url = directory.appendingPathComponent(identifier)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let direct = identifier == identity.bundleID
                // macOS names a container after the executable it made it
                // for, so one named inside this application's identifier is
                // a component's own. Ranked as a guess, the widget's and the
                // background agent's containers were left unticked and
                // outlived every uninstall.
                let owned = identity.ownsIdentifier(identifier)
                return Evidence(
                    url: url, tier: owned ? .A : .C,
                    mechanism: "SandboxContainerSource",
                    humanSentence: direct
                        ? "Sandbox container keyed to this bundle identifier"
                        : owned ? "Sandbox container of a part of this application."
                        : "Container keyed to an embedded component."
                )
            }
        }
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
