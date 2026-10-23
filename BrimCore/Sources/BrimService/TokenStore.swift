import Foundation
import BrimCore
import BrimProtocol

public struct TokenRecord: Codable, Sendable {
    public let planId: UUID
    public let planHash: String
    public let requesterIdentity: String
    public let expiresAt: Date
}

/// The minted tokens, held in memory and nowhere else. Approval is a claim
/// that a person is present now, which does not belong on disk where it
/// could outlive them or be read and spent by another program. Two
/// processes cannot share an approval, on purpose.
public actor TokenStore {
    private var tokens: [UUID: TokenRecord] = [:]
    private let timeToLive: TimeInterval = 300 // 5 minutes
    private let currentTime: @Sendable () -> Date

    public init() {
        currentTime = Date.init
    }

    /// A controlled clock for expiry tests, never supplied over the service protocol.
    init(currentTime: @escaping @Sendable () -> Date) {
        self.currentTime = currentTime
    }

    /// Called from exactly one place, `BrimService.grantApproval(for:)`, after a
    /// person has answered. `ApprovalGateTests` fails if that changes.
    public func mintToken(planId: UUID, planHash: String, requesterIdentity: String) -> ApprovalToken {
        let now = currentTime()
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

    /// Why a token was refused, in plain words: a refusal is the whole message a
    /// person gets.
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

        guard currentTime() < record.expiresAt else {
            tokens.removeValue(forKey: token.nonce)
            throw TokenError.expired
        }

        // Single use: spent on the first attempt, successful or not, so it cannot
        // be retried against a changed disk.
        tokens.removeValue(forKey: token.nonce)

        guard record.planId == expectedPlanId && record.planHash == expectedPlanHash else {
            throw TokenError.planMismatch
        }

        // The token's copy of the binding must match the record; they are minted
        // together, so a mismatch means the token was not the one minted.
        guard token.planHash == record.planHash,
              token.requester == record.requesterIdentity else {
            throw TokenError.planMismatch
        }

        guard record.requesterIdentity == expectedRequesterIdentity else {
            throw TokenError.requesterMismatch
        }
    }
}
