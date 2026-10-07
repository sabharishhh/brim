import BrimCore
import BrimProtocol
import Foundation

actor UninstallStub: BrimServiceProtocol, ApprovalGranting {
    var planToReturn: Plan?
    var planError: Error?
    var approvalError: Error?
    var applyError: Error?
    var verifyResult: VerificationResult?
    var verifyError: Error?

    private(set) var approvals = 0
    private(set) var applies = 0
    private(set) var verifies = 0

    init(
        plan: Plan? = nil,
        planError: Error? = nil,
        approvalError: Error? = nil,
        applyError: Error? = nil,
        verifyResult: VerificationResult? = nil,
        verifyError: Error? = nil
    ) {
        planToReturn = plan
        self.planError = planError
        self.approvalError = approvalError
        self.applyError = applyError
        self.verifyResult = verifyResult
        self.verifyError = verifyError
    }

    func plan(intent _: PlanIntent) async throws -> Plan {
        if let planError {
            throw planError
        }
        return planToReturn!
    }

    func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalRequestReceipt {
        approvals += 1
        if let approvalError {
            throw approvalError
        }
        return .stub(planId: planId, requester: requesterIdentity)
    }

    func grantApproval(for receipt: ApprovalRequestReceipt) async throws -> ApprovalToken {
        .stub(requester: receipt.requester)
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {
        applies += 1
        if let applyError {
            throw applyError
        }
    }

    func verify(planId _: UUID) async throws -> VerificationResult {
        verifies += 1
        if let verifyError {
            throw verifyError
        }
        return verifyResult!
    }

    struct Counts {
        let approvals: Int
        let applies: Int
        let verifies: Int
    }

    func counts() -> Counts {
        Counts(approvals: approvals, applies: applies, verifies: verifies)
    }

    func inspect(identity _: Identity) async throws -> Footprint {
        throw Oops.unavailable
    }

    func history() async throws -> [Plan] {
        []
    }

    func undo(planId _: UUID) async throws {
        throw Oops.unavailable
    }

    func installedApplications() async throws -> [InstalledApplication] {
        []
    }

    func leftovers() async throws -> [Leftover] {
        []
    }

    func recoverableItems() async throws -> [RecoverableItem] {
        []
    }
}

enum Oops: Error, LocalizedError {
    case unavailable
    case refused
    var errorDescription: String? {
        self == .refused ? "User cancelled authentication." : "no"
    }
}
