import BrimCore
import Foundation

/// Computes an on-demand, non-stored projection of an app's footprint on disk.
public struct FootprintProjector: Sendable {
    public let engine: EvidenceEngine

    public init(engine: EvidenceEngine) {
        self.engine = engine
    }

    /// Builds the footprint for an identity, reading sizes and presence fresh
    /// each time.
    public func project(
        identity: Identity, in root: FileSystemRoot, explicitEvidence: [Evidence]? = nil
    ) async throws -> Footprint {
        let evidenceList: [Evidence]
        var completeness = ScanCompleteness.complete
        if let explicit = explicitEvidence {
            // The caller named the targets, so there was no search to be incomplete.
            evidenceList = explicit
        } else {
            let app = try await engine.discover(identity: identity, in: root)
            evidenceList = app.evidence
            completeness = app.completeness
        }

        let items = try await Self.measureItems(evidenceList)
        let sizing = items.compactMap(\.sizeMeasurement).reduce(ScanCompleteness.complete) {
            $0.merging($1.completeness)
        }
        return Footprint(identity: identity, items: items, completeness: completeness.merging(sizing))
    }

    /// Structured work retains the caller's cancellation, unlike Task.detached.
    @concurrent
    private static func measureItems(_ evidenceList: [Evidence]) async throws -> [FootprintItem] {
        let items: [FootprintItem?] = try await BoundedTasks.map(evidenceList) { evidence in
            try Task.checkCancellation()
            // A Boolean existence check also hides permission and link-loop
            // failures. Skip only proven absence; measure every other result
            // without following the entry itself, including a broken link.
            var information = stat()
            if lstat(evidence.url.path, &information) != 0, errno == ENOENT || errno == ENOTDIR {
                return nil
            }
            // Protected by macOS for itself: never the app's to remove, and never
            // removable by anyone.
            if RemovalCapability.isProtectedBySystem(evidence.url.path) {
                return nil
            }
            let measured = ArtifactSizer.measure(at: evidence.url)
            try Task.checkCancellation()
            return FootprintItem(
                evidence: evidence, sizeBytes: measured.logicalBytes,
                capability: determineCapability(for: evidence.url.path),
                unreadableEntries: measured.completeness.unreadable.count + measured.completeness.timedOut.count,
                sizeMeasurement: measured
            )
        }
        return items.compactMap(\.self)
    }

    /// The same answer the leftovers sweep gives, from the same rule: the
    /// folder's permission, asked with `lstat`, not the item's with `access`,
    /// which follows links and is the wrong question for a read-only file.
    private nonisolated static func determineCapability(for path: String) -> Capability {
        RemovalCapability.forDeleting(path)
    }

    struct Measurement: Sendable {
        var bytes: Int64 = 0
        var unreadable: Int = 0
    }

    nonisolated static func measure(at url: URL, fm _: FileManager) -> Measurement {
        let size = ArtifactSizer.measure(at: url)
        return Measurement(bytes: size.logicalBytes,
                           unreadable: size.completeness.unreadable.count + size.completeness.timedOut.count)
    }
}
