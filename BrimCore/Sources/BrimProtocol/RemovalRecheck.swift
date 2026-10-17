import Foundation

/// A finished removal looked at again later. Files can come back after a
/// removal (a helper writes its settings again, a sync restores a folder),
/// so this is the second look. Never saved: it is recomputed each time.
public struct RemovalRecheck: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        /// Everything the removal took is still gone.
        case stillGone
        /// These paths are on the disk again, outermost first.
        case cameBack([String])
        /// The application is installed again, so its files returning is
        /// expected rather than a removal coming undone.
        case installedAgain
    }

    public let planId: UUID
    public let state: State
    public let observedAt: Date

    public var id: UUID {
        planId
    }

    public init(planId: UUID, state: State, observedAt: Date) {
        self.planId = planId
        self.state = state
        self.observedAt = observedAt
    }
}
