import Foundation
import BrimProtocol

/// Stand-ins for the approval round trip, so a test double does not have to
/// restate the whole shape of a receipt every time it is asked for one.
extension ApprovalRequestReceipt {
    static func stub(
        planId: UUID = UUID(), requester: String = "test-user", planHash: String = "hash"
    ) -> ApprovalRequestReceipt {
        ApprovalRequestReceipt(
            requestId: UUID(), planId: planId, planHash: planHash, requester: requester,
            requestedAt: Date(), expiresAt: Date().addingTimeInterval(300),
            summary: "Remove something.", awaitingHuman: true
        )
    }
}

extension ApprovalToken {
    static func stub(planHash: String = "hash", requester: String = "test-user") -> ApprovalToken {
        ApprovalToken(
            planHash: planHash, requester: requester,
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(300), nonce: UUID()
        )
    }
}
