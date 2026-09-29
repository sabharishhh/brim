import BrimCore
import Foundation

/// What an application keeps one level inside a folder that is not its
/// own (Tier B).
///
/// The locations Brim knows are read at their top level, and an app that
/// files its data inside another folder was invisible. Antigravity keeps
/// 244 MB in `~/.gemini/antigravity`, inside the folder the Gemini tools
/// share, and SDKs keep one child per app inside their own cache folder.
/// So the children of the home folder's dot folders and of the places apps
/// keep data are read as well, and a child counts in one of two ways only:
/// it is named with one of the application's identifiers, or it is named
/// for the application and macOS records the application as having written
/// it. A name alone never counts. `~/Documents/antigravity` is somebody's
/// project, and the person's own folders are never read.
public struct NestedFolderSource: EvidenceSource {
    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        await scan(for: identity, in: root).evidence
    }

    public func scan(for identity: Identity, in root: FileSystemRoot) async -> EvidenceFindings {
        let identifiers = identity.searchBundleIdentifiers.map { $0.lowercased() }.filter { !$0.isEmpty }
        let names = ProvenanceSource.names(for: identity)
        guard !identifiers.isEmpty || !names.isEmpty else { return EvidenceFindings(evidence: []) }
        let stamp = identity.bundlePath.flatMap(ProvenanceSource.provenance)
        var evidence: [Evidence] = []
        for parent in Self.parents(in: root) {
            let parentName = parent.lastPathComponent
            // A folder named for the application is the application's
            // already, and macOS's own folders hold nothing of anyone else's.
            if ProvenanceSource.isNamed(parentName, identifiers: identifiers, names: names)
                || LeftoversScanner.isAppleOwned(parentName) { continue }
            guard case let .listed(children) = DirectoryEntries.read(parent) else { continue }
            for child in children.prefix(500) {
                let url = parent.appendingPathComponent(child)
                if Self.isNamedWithIdentifier(child, identifiers) {
                    evidence.append(Evidence(
                        url: url, tier: .B, mechanism: "NestedFolderSource",
                        humanSentence: "Named for \(identity.name) inside \(parentName)."))
                } else if let stamp, ProvenanceSource.isNamed(child, identifiers: [], names: names),
                          ProvenanceSource.provenance(url.path) == stamp {
                    evidence.append(Evidence(
                        url: url, tier: .B, mechanism: "NestedFolderSource",
                        humanSentence: "macOS records that \(identity.name) created this inside \(parentName)."))
                }
            }
        }
        return EvidenceFindings(evidence: evidence)
    }

    /// The folders whose children are read: the home folder's dot folders
    /// and the places applications keep their own data.
    static func parents(in root: FileSystemRoot) -> [URL] {
        let home = root.url(for: .userLibrary).deletingLastPathComponent()
        var parents: [URL] = []
        if case let .listed(entries) = DirectoryEntries.read(home) {
            parents += entries.filter { $0.hasPrefix(".") && $0 != ".Trash" }
                .map { home.appendingPathComponent($0) }
        }
        for domain in [FileSystemRoot.Domain.userApplicationSupport, .userCaches, .userLogs,
                       .userDotConfig, .userDotCache, .userDotLocalShare] {
            let folder = root.url(for: domain)
            guard case let .listed(entries) = DirectoryEntries.read(folder) else { continue }
            parents += entries.filter { !$0.hasPrefix(".") }.map { folder.appendingPathComponent($0) }
        }
        return parents.filter(Self.isFolder)
    }

    static func isNamedWithIdentifier(_ name: String, _ identifiers: [String]) -> Bool {
        let lowered = name.lowercased()
        let base = lowered.hasSuffix(".plist") ? String(lowered.dropLast(6)) : lowered
        return identifiers.contains { base == $0 || base.hasPrefix($0 + ".") }
    }

    static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }
}
