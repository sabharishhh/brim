import Foundation

/// A finished removal looked at again, some time after it was confirmed.
///
/// A removal's result is true when it is made, and the files it took can
/// come back afterwards: a helper that was still running writes its
/// settings again, a sync restores a folder, the person reinstalls. Brim
/// only ever checked once, so a removal that had quietly come undone still
/// read as done. This is the second look. It is never saved, because it is
/// recomputed every time it is shown and a stored one would go stale.
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
