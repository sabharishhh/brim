import Foundation
import BrimCore

/// Represents a strategy for discovering evidence of an application's footprint on disk.
public protocol EvidenceSource: Sendable {
    /// Returns evidence for the given identity within the scoped file system root.
    func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence]
}
