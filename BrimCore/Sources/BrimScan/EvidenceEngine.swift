import Foundation
import BrimCore

/// The engine revision, bumped whenever heuristic logic changes.
public let EvidenceEngineRevision = "1.0.0"

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
    
    public init(sources: [any EvidenceSource]) {
        self.sources = sources
    }
    
    /// Aggregates, deduplicates by target, resolves tier conflicts, and sorts deterministically.
    public func discover(identity: Identity, in root: FileSystemRoot) async throws -> DiscoveredApp {
        var rawEvidence = [Evidence]()
        var completeness = ScanCompleteness.complete

        for source in sources {
            // A source that knows what it could not reach says so, and
            // the gap travels with the result instead of being lost the
            // moment the evidence is merged.
            if let inventory = source as? LocationInventorySource {
                let found = inventory.findings(for: identity, in: root)
                rawEvidence.append(contentsOf: found.evidence)
                completeness = completeness.merging(found.completeness)
            } else {
                rawEvidence.append(contentsOf: try await source.evidence(for: identity, in: root))
            }
        }
        
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

        for e in rawEvidence {
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
        let sortedEvidence = bestEvidenceByPath.values.sorted { $0.url.path < $1.url.path }
        
        let bundleID = identity.bundleID ?? identity.name
        
        return DiscoveredApp(
            bundleID: bundleID,
            name: identity.name,
            evidence: sortedEvidence,
            engineVersion: EvidenceEngineRevision,
            completeness: completeness
        )
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
