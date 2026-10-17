import Foundation

/// Proof that a person agreed to one specific plan a moment ago: bound to
/// the plan by its hash, to the requester by name and to one use by its
/// nonce. It exists only inside the service that minted it, for minutes, and
/// no method on `BrimServiceProtocol` returns one.
public struct ApprovalToken: Codable, Equatable, Sendable {
    /// Binds to exactly one plan. A plan edited after approval no longer
    /// matches, and `apply` refuses it.
    public let planHash: String
    /// Binds to who asked. A token minted for one requester does not let a
    /// different one apply the same plan.
    public let requester: String
    public let issuedAt: Date
    /// Minutes, not hours. Presence is a claim about now.
    public let expiresAt: Date
    /// Single use. Consumed on the first `apply`, whether it succeeds or not.
    public let nonce: UUID

    public init(
        planHash: String, requester: String,
        issuedAt: Date, expiresAt: Date, nonce: UUID
    ) {
        self.planHash = planHash
        self.requester = requester
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.nonce = nonce
    }
}

/// What `requestApproval` gives back: an acknowledgement, not permission. It
/// carries no authority; only a person in Brim's own window, through
/// `ApprovalGranting`, turns it into a token.
public struct ApprovalRequestReceipt: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let planId: UUID
    public let planHash: String
    public let requester: String
    public let requestedAt: Date
    /// After this, the request is stale and has to be made again.
    public let expiresAt: Date
    /// What the person will be asked to agree to, in their words.
    public let summary: String
    /// True while nobody has answered, which is always the case when it is
    /// returned.
    public let awaitingHuman: Bool

    public init(
        requestId: UUID, planId: UUID, planHash: String, requester: String,
        requestedAt: Date, expiresAt: Date, summary: String, awaitingHuman: Bool
    ) {
        self.requestId = requestId
        self.planId = planId
        self.planHash = planHash
        self.requester = requester
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.summary = summary
        self.awaitingHuman = awaitingHuman
    }
}

/// Where a yes comes from. The service mints a token only if something in
/// its own process can put the decision in front of a person; Brim's app
/// installs this at launch. Nothing outside the process can reach the
/// service, so there is no route from a plan to a token at all.
public struct ConsentSource: Sendable {
    /// Puts the decision in front of the person and reports what they said.
    public let ask: @Sendable (ApprovalRequestReceipt) async -> Bool

    public init(ask: @escaping @Sendable (ApprovalRequestReceipt) async -> Bool) {
        self.ask = ask
    }
}

/// Proving a person is at the Mac right now. Injected, because the real one
/// shows a Touch ID dialog and waits, and a test of the approval gate must
/// not stop on a prompt nobody will answer.
public struct PresenceCheck: Sendable {
    /// Throws if the person is not there, or said no.
    public let prove: @Sendable (_ reason: String) async throws -> Void

    public init(prove: @escaping @Sendable (_ reason: String) async throws -> Void) {
        self.prove = prove
    }
}

/// The channel a human decision travels back along.
///
/// Kept off `BrimServiceProtocol` on purpose, and the service is reachable
/// only inside Brim's own process, so anything holding the protocol has no
/// method to call rather than a guard to argue with.
public protocol ApprovalGranting: Sendable {
    func grantApproval(for receipt: ApprovalRequestReceipt) async throws -> ApprovalToken
}

/// Why an approval did not happen.
public enum ApprovalError: LocalizedError, Equatable {
    /// Nothing in this process can ask a person, so nothing here can approve.
    case noHumanToAsk
    /// The person said no.
    case declined
    /// The request has aged out, or was never made.
    case requestNotPending
    /// The plan changed between the request and the answer.
    case planChangedSinceRequest

    public var errorDescription: String? {
        switch self {
        case .noHumanToAsk:
            return "Approvals happen in Brim's window, and there is no window here. "
                 + "Open Brim and confirm the removal there."
        case .declined:
            return "You did not approve this, so nothing was touched."
        case .requestNotPending:
            return "That approval request has expired. Ask again and it will be rebuilt "
                 + "from what is on disk now."
        case .planChangedSinceRequest:
            return "What this plan would do changed while it was waiting, so the old "
                 + "approval no longer covers it."
        }
    }
}
