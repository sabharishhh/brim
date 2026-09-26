import BrimCore
import Foundation

/// Represents a strategy for discovering evidence of an application's footprint on disk.
public protocol EvidenceSource: Sendable {
    /// Returns evidence for the given identity within the scoped file system root.
    func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence]

    /// Sources that recover from individual read failures carry those gaps here.
    func scan(for identity: Identity, in root: FileSystemRoot) async throws -> EvidenceFindings
}

public struct EvidenceFindings: Sendable {
    public let evidence: [Evidence]
    public let completeness: ScanCompleteness

    public init(evidence: [Evidence], completeness: ScanCompleteness = .complete) {
        self.evidence = evidence
        self.completeness = completeness
    }
}

public extension EvidenceSource {
    func scan(for identity: Identity, in root: FileSystemRoot) async throws -> EvidenceFindings {
        try await EvidenceFindings(evidence: evidence(for: identity, in: root))
    }
}
