import Foundation
import BrimCore
import BrimProtocol
import BrimService

@MainActor
public class BrimClient: ObservableObject {
    public static let shared = BrimClient()
    
    public var service: (any BrimServiceProtocol)?
    
    public init() {}
    
    public func plan(intent: PlanIntent) async throws -> Plan {
        guard let service = service else { throw NSError(domain: "BrimClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Service not connected"]) }
        return try await service.plan(intent: intent)
    }
    
    public func execute(plan: Plan, requesterIdentity: String) async throws -> VerificationResult {
        guard let service = service else { throw NSError(domain: "BrimClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Service not connected"]) }
        
        try await service.approveAndApply(
            planId: plan.planId, requesterIdentity: requesterIdentity
        )
        return try await service.verify(planId: plan.planId)
    }
}
