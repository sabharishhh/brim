import BrimCore
import BrimProtocol
import Foundation

struct FailingAppsService: BrimServiceProtocol {
    func installedApplications() async throws -> [InstalledApplication] {
        throw ListingFailure.unavailable
    }

    func inspect(identity _: Identity) async throws -> Footprint {
        throw ListingFailure.unavailable
    }

    func plan(intent _: PlanIntent) async throws -> Plan {
        throw ListingFailure.unavailable
    }

    func explain(planId _: UUID) async throws -> String {
        throw ListingFailure.unavailable
    }

    func requestApproval(planId _: UUID, requesterIdentity _: String) async throws -> ApprovalRequestReceipt {
        throw ListingFailure.unavailable
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {
        throw ListingFailure.unavailable
    }

    func verify(planId _: UUID) async throws -> VerificationResult {
        throw ListingFailure.unavailable
    }

    func history() async throws -> [Plan] {
        []
    }

    func undo(planId _: UUID) async throws {
        throw ListingFailure.unavailable
    }

    func leftovers() async throws -> [Leftover] {
        []
    }

    func recoverableItems() async throws -> [RecoverableItem] {
        []
    }
}

private enum ListingFailure: Error { case unavailable }
