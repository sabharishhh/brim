import Foundation
import BrimCore
import BrimProtocol

public struct TokenRecord: Codable, Sendable {
    public let planId: UUID
    public let planHash: String
    public let requesterIdentity: String
    public let expiresAt: Date
}

public actor TokenStore {
    private var tokens: [String: TokenRecord] = [:]
    private let timeToLive: TimeInterval = 300 // 5 minutes
    private let storeURL: URL
    
    public init(directoryURL: URL) {
        self.storeURL = directoryURL.appendingPathComponent("tokens.json")
        self.tokens = TokenStore.loadFromDisk(storeURL: self.storeURL)
    }
    
    private static func loadFromDisk(storeURL: URL) -> [String: TokenRecord] {
        guard let data = try? Data(contentsOf: storeURL),
              let loaded = try? JSONDecoder().decode([String: TokenRecord].self, from: data) else {
            return [:]
        }
        // Filter out expired tokens on load
        let now = Date()
        return loaded.filter { $0.value.expiresAt > now }
    }
    
    private func saveToDisk() {
        // Atomic write
        let tempURL = storeURL.appendingPathExtension("tmp")
        do {
            let data = try JSONEncoder().encode(tokens)
            try data.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tempURL)
        } catch {
            print("Warning: failed to persist tokens to disk: \(error)")
        }
    }
    
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
        saveToDisk()
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
        
        guard Date() < record.expiresAt else {
            throw TokenError.expired
        }
        
        // Single use: remove it immediately on success
        tokens.removeValue(forKey: token.token)
        saveToDisk()
        
        guard record.planId == expectedPlanId && record.planHash == expectedPlanHash else {
            throw TokenError.planMismatch
        }
        
        guard record.requesterIdentity == expectedRequesterIdentity else {
            throw TokenError.requesterMismatch
        }
    }
}
