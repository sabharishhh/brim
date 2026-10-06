import BrimCore
import Foundation

/// The engine revision, bumped whenever heuristic logic changes.
public let EvidenceEngineRevision = "1.2.0"

/// The discovered application artifact containing deduplicated and sorted evidence.
public struct DiscoveredApp: AppArtifact {
    public let bundleID: String
    public let name: String
    public let evidence: [Evidence]
    public let engineVersion: String
    /// What the search did not manage to see. Carried rather than
    /// discarded, because a list that came from an unfinished search
    /// cannot support the claim that it is the whole footprint.
    public let completeness: ScanCompleteness

    public init(
        bundleID: String, name: String, evidence: [Evidence], engineVersion: String,
        completeness: ScanCompleteness = .complete
    ) {
        self.bundleID = bundleID
        self.name = name
        self.evidence = evidence
        self.engineVersion = engineVersion
        self.completeness = completeness
    }
}

/// A deterministic engine that aggregates evidence from multiple sources.
public struct EvidenceEngine: Sendable {
    public let sources: [any EvidenceSource]

    /// The production removal search, shared with the direction-agreement
    /// test so a newly added source cannot silently drift from the sweep.
    public static var standard: EvidenceEngine {
        EvidenceEngine(sources: [
            AppBundleSource(), SandboxContainerSource(), InstallerReceiptSource(),
            BundleIdentifierComponentSource(), LocationInventorySource(),
            SymlinkIntoBundleSource(), GroupContainerSource(), BundleIdentifierStateSource(),
            TeamIDSource(), LaunchServicesSource(), SMAppServiceSource(), LaunchdSource(),
            ProvenanceSource(), NestedFolderSource()
        ])
    }

    public init(sources: [any EvidenceSource]) {
        self.sources = sources
    }

    /// Aggregates, deduplicates by target, resolves tier conflicts, and sorts deterministically.
    public func discover(identity: Identity, in root: FileSystemRoot) async throws -> DiscoveredApp {
        var rawEvidence = [Evidence]()
        var completeness = ScanCompleteness.complete

        let findings = try await scanSources(identity: identity, in: root)
        for found in findings {
            rawEvidence.append(contentsOf: found.evidence)
            completeness = completeness.merging(found.completeness)
        }

        // Follow the trail. What was found names more of the application:
        // a helper application the same installer put down outside the
        // Applications folders (Microsoft AutoUpdate came with Teams and kept
        // its caches under its own name), a helper inside one of the
        // application's folders, or the program one of its launch jobs runs.
        // Each is searched for in turn, and what it finds may name another,
        // for up to three rounds. A helper found any way but the installer's
        // receipt counts only when the same developer signed it, so a shared
        // updater another product installed is never pulled in.
        let subject = identity.bundlePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var followed = Set([subject].compactMap(\.self))
        var frontier = Self.parts(in: rawEvidence, excluding: followed)
        for _ in 0 ..< 3 where !frontier.isEmpty {
            var next: [Evidence] = []
            for (helper, receiptProven) in frontier {
                followed.insert(helper.standardizedFileURL.path)
                let part = await IdentityResolver(root: root).resolve(bundleURL: helper)
                guard receiptProven || (part.teamID != nil && part.teamID == identity.teamID) else { continue }
                let sentence = receiptProven
                    ? "Belongs to \(part.name), which was installed with \(identity.name)."
                    : "Belongs to \(part.name), a helper of \(identity.name) from the same developer."
                // Listed only where nothing already in the removal holds it,
                // so the plan never names one bundle twice.
                let held = rawEvidence.contains {
                    helper.standardizedFileURL.path.hasPrefix($0.url.standardizedFileURL.path + "/")
                }
                if !receiptProven, !held {
                    next.append(Evidence(url: helper, tier: .B, mechanism: "HelperSource", humanSentence: sentence))
                }
                for found in try await scanSources(identity: part, in: root, forPart: true) {
                    completeness = completeness.merging(found.completeness)
                    next += found.evidence.map { evidence in
                        // What a part keeps is known through the part, one step
                        // further from the application than its own files.
                        Evidence(url: evidence.url, tier: evidence.tier == .A ? .B : evidence.tier,
                                 mechanism: evidence.mechanism,
                                 humanSentence: evidence.tier == .S ? evidence.humanSentence : sentence)
                    }
                }
            }
            rawEvidence += next
            frontier = Self.parts(in: next, excluding: followed)
        }

        let sortedEvidence = deduplicatedEvidence(rawEvidence)

        let bundleID = identity.bundleID ?? identity.name

        return DiscoveredApp(
            bundleID: bundleID,
            name: identity.name,
            evidence: sortedEvidence,
            engineVersion: EvidenceEngineRevision,
            completeness: completeness
        )
    }

    private func deduplicatedEvidence(_ evidence: [Evidence]) -> [Evidence] {
        // Deduplicate and resolve tier conflicts.
        //
        // Keyed on the file itself rather than on the string naming it.
        // Almost every Mac has a case-insensitive volume, so
        // `/usr/local/bin/Code` and `/usr/local/bin/code` are one file, and
        // two sources that spell it differently were producing two rows: one
        // from a name match, one from following the symbolic link, each with
        // its own tier and its own sentence. A plan that offers to remove
        // the same file twice is wrong twice over, because the second row
        // says something is there that is not.
        //
        // `dev` and `ino` are what `TargetFingerprint` already uses to decide
        // whether a plan is still pointing at what it was built against, so
        // this is the same notion of sameness the executor holds.
        var bestEvidenceByFile = [String: Evidence]()

        for found in evidence {
            // Spelled as stored, whichever spelling the source asked with.
            let spelled = OnDiskName.spelled(found.url)
            let e = spelled == found.url ? found
                : Evidence(url: spelled, tier: found.tier, mechanism: found.mechanism,
                           humanSentence: found.humanSentence)
            let key = Self.identity(of: e.url)
            if let existing = bestEvidenceByFile[key] {
                // Tier comparison: S > A > B > C
                if isStronger(e.tier, than: existing.tier) {
                    bestEvidenceByFile[key] = e
                }
            } else {
                bestEvidenceByFile[key] = e
            }
        }
        let bestEvidenceByPath = bestEvidenceByFile

        // Sort deterministically (alphabetically by path)
        return bestEvidenceByPath.values.sorted { $0.url.path < $1.url.path }
    }

    /// Helper applications the evidence names, and whether an installer
    /// receipt proves each one came with the application.
    static func parts(in evidence: [Evidence], excluding followed: Set<String>) -> [(URL, Bool)] {
        var parts: [String: (URL, Bool)] = [:]
        func add(_ url: URL, _ receipt: Bool) {
            let path = url.standardizedFileURL.path
            guard !followed.contains(path), !followed.contains(where: { path.hasPrefix($0 + "/") }),
                  !path.contains("/Applications/") || receipt
            else { return }
            parts[path] = (parts[path]?.1 ?? false) || receipt ? (url, true) : (url, false)
        }
        for item in evidence where item.tier != .S {
            if item.mechanism == "InstallerPayloadSource", item.url.pathExtension == "app" {
                add(item.url, true)
            } else if item.url.pathExtension == "app" {
                add(item.url, false)
            } else if item.url.pathExtension == "plist", let bundle = launchBundle(item.url) {
                add(bundle, false)
            } else if isFolder(item.url) {
                for bundle in bundles(inside: item.url) {
                    add(bundle, false)
                }
            }
        }
        return Array(parts.values)
    }

    /// The outermost application a path runs through.
    static func outermostApp(containing url: URL) -> URL? {
        var path = URL(fileURLWithPath: "/")
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            path.appendPathComponent(component)
            if component.hasSuffix(".app") {
                return path
            }
        }
        return nil
    }

    private static func launchBundle(_ plist: URL) -> URL? {
        launchProgram(plist).flatMap { outermostApp(containing: $0) }
    }

    /// The program a launch job's property list runs.
    static func launchProgram(_ plist: URL) -> URL? {
        guard let info = NSDictionary(contentsOf: plist),
              let path = info["Program"] as? String ?? (info["ProgramArguments"] as? [String])?.first,
              path.hasPrefix("/")
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Applications inside a folder, three levels down at most and a few
    /// thousand entries in all, so a large data folder costs little.
    static func bundles(inside folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 3000 {
                break
            }
            if enumerator.level > 3 {
                enumerator.skipDescendants(); continue
            }
            if url.pathExtension == "app" {
                found.append(url)
            }
        }
        return found
    }

    static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true && values?.isPackage != true
    }

    /// For a part, the bundle itself is already a payload item, and its
    /// receipts are the application's, so neither is read again.
    private func scanSources(
        identity: Identity, in root: FileSystemRoot, forPart: Bool = false
    ) async throws -> [EvidenceFindings] {
        let sources = forPart
            ? sources.filter { !($0 is InstallerReceiptSource) && !($0 is AppBundleSource) }
            : sources
        return try await BoundedTasks.map(sources) { source in
            try await source.scan(for: identity, in: root)
        }
    }

    /// Which of two pieces of evidence for the same path to keep.
    ///
    /// S is deliberately the heaviest, and not because it is the most
    /// confident. It is the opposite: it says something else claims this
    /// path. Whichever source noticed that has to survive being merged
    /// with a confident one, or the veto is thrown away at exactly the
    /// moment it matters.
    private func isStronger(_ t1: EvidenceTier, than t2: EvidenceTier) -> Bool {
        let weight: [EvidenceTier: Int] = [.S: 4, .A: 3, .B: 2, .C: 1]
        return weight[t1]! > weight[t2]!
    }

    /// What makes two pieces of evidence the same thing.
    ///
    /// The volume's own answer where it has one, read with `lstat` so a
    /// symbolic link is itself rather than whatever it points at. A link and
    /// its target are two files and both can be residue; the same file under
    /// two spellings is one.
    ///
    /// Falls back to the path for anything that cannot be stated, which
    /// includes a path that no longer exists by the time the merge runs.
    static func identity(of url: URL) -> String {
        var info = stat()
        guard lstat(url.standardized.path, &info) == 0 else {
            return url.standardized.path
        }
        return "\(info.st_dev):\(info.st_ino)"
    }
}
