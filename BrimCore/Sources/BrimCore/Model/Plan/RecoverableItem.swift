import Foundation

/// A past removal whose contents are still sitting in the Trash, and so can
/// still be put back. Anything permanently deleted, or trashed and since
/// emptied, is absent — the list reflects what is recoverable *now*, not what
/// was once trashed.
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
