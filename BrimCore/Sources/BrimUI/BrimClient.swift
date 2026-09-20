import Foundation
import BrimCore
import BrimProtocol
import BrimService

@MainActor
public class BrimClient: ObservableObject {
    public static let shared = BrimClient()
    
    public var service: (any BrimServiceProtocol)?
    
    // For direct token minting in the same process during development, we'll keep a reference to the concrete store if available.
    // In production, the UI would sign a request with a private key, or XPC would mint it after LAContext.
    public var localTokenStore: TokenStore?
    
    public init() {}
    
    public func plan(intent: PlanIntent) async throws -> Plan {
        guard let service = service else { throw NSError(domain: "BrimClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Service not connected"]) }
        return try await service.plan(intent: intent)
    }
    
    public func execute(plan: Plan, requesterIdentity: String) async throws -> VerificationResult {
        guard let service = service else { throw NSError(domain: "BrimClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Service not connected"]) }
        
        try await service.requestApproval(planId: plan.planId, requesterIdentity: requesterIdentity)
        
        let hash = try plan.contentHash()
        let token: ApprovalToken
        if let store = localTokenStore {
            token = await store.mintToken(planId: plan.planId, planHash: hash, requesterIdentity: requesterIdentity)
        } else if let concrete = service as? BrimService {
            token = await concrete.tokenStore.mintToken(planId: plan.planId, planHash: hash, requesterIdentity: requesterIdentity)
        } else {
            throw NSError(domain: "BrimClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot mint token without local token store access"])
        }
        
        try await service.apply(planId: plan.planId, token: token)
        return try await service.verify(planId: plan.planId)
    }
}
