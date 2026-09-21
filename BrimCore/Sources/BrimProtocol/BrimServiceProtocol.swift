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
    /// Applications installed on this machine, for the Applications view.
    func installedApplications() async throws -> [InstalledApplication]
    func leftovers() async throws -> [Leftover]
    /// Past removals whose contents are still in the Trash, so still restorable.
    func recoverableItems() async throws -> [RecoverableItem]
    func scanDuplicates(in directory: URL) async throws -> [DuplicateGroup]
    /// Clears registrations that became stale since the last look — chiefly
    /// when the user empties the Trash. Cheap, idempotent, and safe to call
    /// on every Trash change.
    func reconcileRegistrations() async
    /// Whether the owner has completed first-run setup.
    func isEnrolled() async -> Bool
    /// First-run setup: one confirmation that this Mac belongs to the person
    /// using it. Never asked again.
    func enroll() async throws
    /// Everything macOS has registered on behalf of software: launchd
    /// jobs, and the login items and background services in Background
    /// Task Management.
    ///
    /// This used to take a flag, because background items came from
    /// `sfltool` and reading them cost an administrator prompt. They are
    /// read from the store directly now, so there is nothing left to opt
    /// into and no reason to withhold half the answer.
    func registrations() async -> RegistrationReport
    /// Space on each local volume, kept as separate figures rather than
    /// collapsed into one.
    func volumes() async -> [VolumeAccount]
    /// A single sample of what is running and what it is costing.
    func sampleEnergy() async -> EnergySampleResult
    /// Build caches this Mac has accumulated, with what clearing each costs.
    func developerCaches() async -> [DeveloperCache]
    /// Plans a tool's own cleanup, named rather than described. The command
    /// is resolved inside the service from a fixed table.
    func planToolCleanup(id: String, displayed: String) async throws -> Plan
}

public extension BrimServiceProtocol {
    /// Nothing to reconcile by default, so a service that does not track
    /// registrations — a test stub, or the XPC client until the daemon
    /// carries this — is not forced to implement it.
    func reconcileRegistrations() async {}

    /// A service that does not track enrolment is already past it, so
    /// nothing prompts. Keeps stubs and the XPC client conforming.
    func isEnrolled() async -> Bool { true }
    func enroll() async throws {}
    func registrations() async -> RegistrationReport { .empty }
    func volumes() async -> [VolumeAccount] { [] }
    func sampleEnergy() async -> EnergySampleResult {
        EnergySampleResult(samples: [], coverageGaps: 0)
    }
    func developerCaches() async -> [DeveloperCache] { [] }
    func planToolCleanup(id: String, displayed: String) async throws -> Plan {
        throw NSError(domain: "BrimService", code: 501,
                      userInfo: [NSLocalizedDescriptionKey: "Not supported here."])
    }
}
