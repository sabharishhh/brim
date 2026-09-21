import Foundation

/// Proof that a person agreed to one specific plan, a moment ago.
///
/// Bound to the plan by its hash, to the requester by name, and to a single
/// use by its nonce. It exists only inside the service that minted it, for
/// minutes, and no method on `BrimServiceProtocol` returns one.
public struct ApprovalToken: Codable, Equatable, Sendable {
    /// Binds to exactly one plan. A plan edited after approval no longer
    /// matches, and `apply` refuses it.
    public let planHash: String
    /// Binds to who asked. A token minted for the app does not let the CLI
    /// apply the same plan.
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

/// What `requestApproval` gives back: an acknowledgement, not permission.
///
/// The receipt says a decision is pending and describes what the decision
/// is about. It carries no authority. Turning one into an `ApprovalToken`
/// takes a human, in Brim's own window, through `ApprovalGranting` — which
/// is deliberately not part of the service protocol.
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
    /// True while nobody has answered. Always true when the receipt is
    /// handed back, because nothing is decided by asking.
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

/// Where a yes comes from.
///
/// The service will not mint a token unless something inside its own
/// process can put the decision in front of a person. Brim's app installs
/// one of these at launch, after it has shown the review sheet. The CLI,
/// the MCP host and anything holding an XPC client never do, so for them
/// there is no route from a plan to a token at all: not a check they might
/// pass, an absence of the machinery.
public struct ConsentSource: Sendable {
    /// Puts the decision in front of the person and reports what they said.
    public let ask: @Sendable (ApprovalRequestReceipt) async -> Bool

    public init(ask: @escaping @Sendable (ApprovalRequestReceipt) async -> Bool) {
        self.ask = ask
    }
}

/// The channel a human decision travels back along.
///
/// Kept off `BrimServiceProtocol` on purpose. `BrimXPCClient` does not
/// conform, and `BrimXPCProtocol` has no matching message, so a caller on
/// the far side of a process boundary has no method to call rather than a
/// guard to argue with.
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
