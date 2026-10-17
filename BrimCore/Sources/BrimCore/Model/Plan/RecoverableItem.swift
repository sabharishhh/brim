import Foundation

/// A past removal whose contents are still in the Trash, so it can be put
/// back. What is recoverable now, not what was once trashed.
public struct RecoverableItem: Codable, Equatable, Sendable, Identifiable {
    public let planId: UUID
    /// What the plan was called, for display.
    public let name: String
    /// Bytes that return to the disk if the user empties the Trash, or to
    /// their original location if they undo.
    public let bytes: Int64
    public let removedAt: Date

    public var id: UUID { planId }

    public init(planId: UUID, name: String, bytes: Int64, removedAt: Date) {
        self.planId = planId
        self.name = name
        self.bytes = bytes
        self.removedAt = removedAt
    }
}
