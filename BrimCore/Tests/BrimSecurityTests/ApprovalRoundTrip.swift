import Foundation
import BrimProtocol
import BrimService

/// The approval round trip in one call.
///
/// Most of these tests are about what happens after a person has said yes,
/// not about the gate itself. Asking and granting are two steps now, on
/// purpose, and this keeps that from being restated in forty places.
/// `ApprovalGateTests` is where the two steps are examined separately.
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
    /// A token nobody minted. Well formed, and worth nothing: the store
    /// has never seen this nonce, so `apply` refuses it.
    static func forged(
        planHash: String = "not-a-real-hash", requester: String = "attacker"
    ) -> ApprovalToken {
        ApprovalToken(
            planHash: planHash, requester: requester,
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(300), nonce: UUID()
        )
    }
}
