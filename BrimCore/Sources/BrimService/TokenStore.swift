import Foundation
import BrimCore
import BrimProtocol

public struct TokenRecord: Codable, Sendable {
    public let planId: UUID
    public let planHash: String
    public let requesterIdentity: String
    public let expiresAt: Date
}

/// The minted tokens, held in memory and nowhere else.
///
/// This used to write `tokens.json` so that `brim approve-request` in one
/// process and `brim apply` in another could share a token. That made a
/// token a file: something that outlived the person who granted it, that
/// survived a relaunch, and that anything able to read the user's
/// Application Support directory could pick up and spend. Approval is a
/// claim about a person being present at this moment, and a claim about
/// now does not belong on disk.
///
/// The cost is real and deliberate: two separate processes cannot share an
/// approval any more. A requester that is not the app has to be connected
/// to the service that minted the token. That is the shape the architecture
/// was always meant to have.
public actor TokenStore {
    private var tokens: [UUID: TokenRecord] = [:]
    private let timeToLive: TimeInterval = 300 // 5 minutes

    public init() {}

    /// Called from exactly one place: `BrimService.grantApproval(for:)`,
    /// after a person has answered. Nothing else in `Sources` calls this,
    /// and `ApprovalGateTests` fails if that stops being true.
    public func mintToken(planId: UUID, planHash: String, requesterIdentity: String) -> ApprovalToken {
        let now = Date()
        let expiry = now.addingTimeInterval(timeToLive)
        let nonce = UUID()
        tokens[nonce] = TokenRecord(
            planId: planId,
            planHash: planHash,
            requesterIdentity: requesterIdentity,
            expiresAt: expiry
        )
        return ApprovalToken(
            planHash: planHash, requester: requesterIdentity,
            issuedAt: now, expiresAt: expiry, nonce: nonce
        )
    }

    /// Why a token was refused, said plainly.
    ///
    /// These reach a person through the CLI, where the whole message is
    /// the error. "Error Domain=TokenError Code=0" tells someone holding a
    /// token that something went wrong and nothing about what, which is
    /// how a refusal gets mistaken for a bug and worked around.
    public enum TokenError: LocalizedError, Equatable {
        case notFound
        case expired
        case planMismatch
        case requesterMismatch

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "Nothing approved this. A token is minted in Brim's window when a "
                     + "person agrees, it is spent the first time it is used, and it does "
                     + "not survive Brim quitting."
            case .expired:
                return "That approval is older than five minutes, so it no longer says "
                     + "anything about who is at the machine now. Ask again."
            case .planMismatch:
                return "That approval was for a different plan, or for this plan before "
                     + "it changed."
            case .requesterMismatch:
                return "That approval was granted to somebody else. A token is bound to "
                     + "whoever asked for it."
            }
        }
    }

    /// Consumes a token and validates it. Throws if invalid.
    public func consumeAndValidate(token: ApprovalToken, expectedPlanId: UUID, expectedPlanHash: String, expectedRequesterIdentity: String) throws {
        guard let record = tokens[token.nonce] else {
            throw TokenError.notFound
        }

        guard Date() < record.expiresAt else {
            tokens.removeValue(forKey: token.nonce)
            throw TokenError.expired
        }

        // Single use: spent on the first attempt, successful or not. A
        // token that survives a failed apply is a token worth retrying
        // against a changed disk.
        tokens.removeValue(forKey: token.nonce)

        guard record.planId == expectedPlanId && record.planHash == expectedPlanHash else {
            throw TokenError.planMismatch
        }

        // The token's own copy of the binding has to agree with the record.
        // They are minted together, so a disagreement means the value the
        // caller handed over was not the value that was minted.
        guard token.planHash == record.planHash,
              token.requester == record.requesterIdentity else {
            throw TokenError.planMismatch
        }

        guard record.requesterIdentity == expectedRequesterIdentity else {
            throw TokenError.requesterMismatch
        }
    }
}
