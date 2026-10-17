import BrimCore
import Foundation

/// What an application keeps one level inside a folder that is not its own
/// (Tier B), such as `~/.gemini/antigravity`. A child of a dot folder or a
/// data folder counts only when it is named with one of the app's
/// identifiers, or named for the app and recorded by macOS as written by it.
/// A name alone never counts, and the person's own folders are never read.
public struct NestedFolderSource: EvidenceSource {
    private let budget: @Sendable () -> ScanBudget

    public init(budget: @escaping @Sendable () -> ScanBudget = { ScanBudget() }) {
        self.budget = budget
    }

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        await scan(for: identity, in: root).evidence
    }

    public func scan(for identity: Identity, in root: FileSystemRoot) async -> EvidenceFindings {
        let identifiers = identity.searchBundleIdentifiers.map { $0.lowercased() }.filter { !$0.isEmpty }
        let names = ProvenanceSource.names(for: identity)
        guard !identifiers.isEmpty || !names.isEmpty else { return EvidenceFindings(evidence: []) }
        let stamp = identity.bundlePath.flatMap(ProvenanceSource.provenance)
        var search = DirectorySearch(budget: budget())
        var evidence: [Evidence] = []
        let parents = Self.parents(in: root, search: &search)
        let caches = root.url(for: .userCaches).standardizedFileURL.path
        let crashReporters = CrashReporterFolders(identity: identity)
        for parent in parents {
            let parentName = parent.lastPathComponent
            let inCaches = parent.deletingLastPathComponent().standardizedFileURL.path == caches
            if inCaches, let found = crashReporters.evidence(in: parent, search: &search) {
                evidence += found
                continue
            }
            // A folder named for the application is already its own, and macOS's own
            // folders hold nothing of anyone else's.
            let skipParent = ProvenanceSource.isNamed(parentName, identifiers: identifiers, names: names)
                || LeftoversScanner.isAppleOwned(parentName)
            if skipParent {
                continue
            }
            for child in search.entries(parent) {
                guard search.canContinue(at: parent) else { break }
                let url = parent.appendingPathComponent(child)
                if let matched = Self.identifier(naming: child, identifiers) {
                    // An identifier in another developer's namespace ships in other apps too,
                    // so here it is a name match.
                    evidence.append(Evidence(
                        url: url, tier: identity.ownsIdentifier(matched) ? .B : .C,
                        mechanism: "NestedFolderSource",
                        humanSentence: "Named for \(identity.name) inside \(parentName)."
                    ))
                } else if let stamp {
                    let named = ProvenanceSource.isNamed(child, identifiers: [], names: names)
                    guard named, ProvenanceSource.provenance(url.path) == stamp else { continue }
                    evidence.append(Evidence(
                        url: url, tier: .B, mechanism: "NestedFolderSource",
                        humanSentence: "macOS records that \(identity.name) created this inside \(parentName)."
                    ))
                }
            }
        }
        return EvidenceFindings(evidence: evidence, completeness: search.completeness)
    }

    /// The folders whose children are read: the home folder's dot folders
    /// and the places applications keep their own data.
    private static func parents(in root: FileSystemRoot, search: inout DirectorySearch) -> [URL] {
        let home = root.url(for: .userLibrary).deletingLastPathComponent()
        let locations = [(home, true)] + [FileSystemRoot.Domain.userApplicationSupport, .userCaches, .userLogs,
                                          .userDotConfig, .userDotCache, .userDotLocalShare]
            .map { (root.url(for: $0), false) }
        var parents: [URL] = []
        for (directory, hiddenOnly) in locations {
            let names = search.entries(directory).filter {
                hiddenOnly ? $0.hasPrefix(".") && $0 != ".Trash" : !$0.hasPrefix(".")
            }
            for name in names {
                guard search.canContinue(at: directory) else { break }
                let url = directory.appendingPathComponent(name)
                do {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isDirectory == true, values.isSymbolicLink != true {
                        parents.append(url)
                    }
                } catch {
                    // A vanished child is absent; other stat failures hide a possible parent.
                    if !DirectoryEntries.isMissing(error) {
                        search.unreadable.append(url.path)
                    }
                }
            }
        }
        return parents
    }

    static func isNamedWithIdentifier(_ name: String, _ identifiers: [String]) -> Bool {
        identifier(naming: name, identifiers) != nil
    }

    /// The longest of the identifiers the name is, or is inside.
    static func identifier(naming name: String, _ identifiers: [String]) -> String? {
        let lowered = name.lowercased()
        let base = lowered.hasSuffix(".plist") ? String(lowered.dropLast(6)) : lowered
        return identifiers.filter { base == $0 || base.hasPrefix($0 + ".") }.max { $0.count < $1.count }
    }

    static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }
}
