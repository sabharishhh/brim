import Foundation
import BrimCore

/// The single API, behind which everything hides.
/// All parameters and returns are value types, ready to cross a process boundary in M2.
public protocol BrimServiceProtocol: Sendable {
    func inspect(identity: Identity) async throws -> Footprint
    func plan(intent: PlanIntent) async throws -> Plan
    func explain(planId: UUID) async throws -> String
        func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalToken
    func apply(planId: UUID, token: ApprovalToken) async throws
    func verify(planId: UUID) async throws -> VerificationResult
    func history() async throws -> [Plan]
    func undo(planId: UUID) async throws
    func dumpBTM() async throws -> String
}
