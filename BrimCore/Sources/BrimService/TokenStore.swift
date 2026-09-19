import Foundation
import BrimCore
import BrimProtocol

public struct TokenRecord: Sendable {
    public let planId: UUID
    public let planHash: String
    public let requesterIdentity: String
    public let expiresAt: Date
}

public actor TokenStore {
    private var tokens: [String: TokenRecord] = [:]
    private let timeToLive: TimeInterval = 300 // 5 minutes
    
    public init() {}
    
    /// Called only by the UI when a human approves a plan.
    public func mintToken(planId: UUID, planHash: String, requesterIdentity: String) -> ApprovalToken {
        let rawToken = UUID().uuidString
        let record = TokenRecord(
            planId: planId,
            planHash: planHash,
            requesterIdentity: requesterIdentity,
            expiresAt: Date().addingTimeInterval(timeToLive)
        )
        tokens[rawToken] = record
        return ApprovalToken(token: rawToken)
    }
    
    public enum TokenError: Error, Equatable {
        case notFound
        case expired
        case planMismatch
        case requesterMismatch
    }
    
    /// Consumes a token and validates it. Throws if invalid.
    public func consumeAndValidate(token: ApprovalToken, expectedPlanId: UUID, expectedPlanHash: String, expectedRequesterIdentity: String) throws {
        guard let record = tokens[token.token] else {
            throw TokenError.notFound
        }
        
        // Single use: remove it immediately
        tokens.removeValue(forKey: token.token)
        
        guard Date() < record.expiresAt else {
            throw TokenError.expired
        }
        
        guard record.planId == expectedPlanId && record.planHash == expectedPlanHash else {
            throw TokenError.planMismatch
        }
        
        guard record.requesterIdentity == expectedRequesterIdentity else {
            throw TokenError.requesterMismatch
        }
    }
}
