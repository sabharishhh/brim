import Foundation
import BrimProtocol
import BrimService

/// Request and grant in one call, for tests about what happens after a yes.
/// `ApprovalGateTests` examines the two steps separately.
extension BrimServiceProtocol {
    func approvedToken(planId: UUID, requester: String) async throws -> ApprovalToken {
        let receipt = try await requestApproval(planId: planId, requesterIdentity: requester)
        guard let granting = self as? ApprovalGranting else {
            throw ApprovalError.noHumanToAsk
        }
        return try await granting.grantApproval(for: receipt)
    }
}

extension ApprovalToken {
    /// A well-formed token nobody minted: `apply` refuses it.
    static func forged(
        planHash: String = "not-a-real-hash", requester: String = "attacker"
    ) -> ApprovalToken {
        ApprovalToken(
            planHash: planHash, requester: requester,
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(300), nonce: UUID()
        )
    }
}
