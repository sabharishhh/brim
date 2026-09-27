import BrimCore
import BrimProtocol
@testable import BrimUI
import XCTest

/// Leftovers are grouped by what can safely go, and a kept group stays kept.
@MainActor
final class LeftoverGroupingTests: XCTestCase {
    private func leftover(_ path: String, _ category: Leftover.Category, capability: Capability = .ok) -> Leftover {
        Leftover(
            url: URL(fileURLWithPath: path), size: 1024, category: category,
            evidence: "evidence", capability: capability
        )
    }

    func testWhatBrimCannotRemoveIsNeverOfferedAsRemovable() {
        let groups = [
            leftover("/Users/me/Library/Caches/com.gone.app", .orphaned),
            leftover("/Library/Application Support/Vendor", .unclaimed, capability: .refusedByOS)
        ].groupedByOwner()
        let grouped = LeftoverGrouper().groups(groups, by: .smart) { _ in false }
        XCTAssertEqual(grouped.map(\.id), ["removed", "staying"])
        XCTAssertTrue(grouped.last?.startsCollapsed ?? false)
    }

    private final class Stub: BrimServiceProtocol, @unchecked Sendable {
        let items: [Leftover]
        init(_ items: [Leftover]) {
            self.items = items
        }

        func leftovers() async throws -> [Leftover] {
            items
        }

        func inspect(identity _: Identity) async throws -> Footprint {
            throw CancellationError()
        }

        func plan(intent _: PlanIntent) async throws -> Plan {
            throw CancellationError()
        }

        func explain(planId _: UUID) async throws -> String {
            ""
        }

        func requestApproval(planId _: UUID, requesterIdentity _: String) async throws -> ApprovalRequestReceipt {
            throw CancellationError()
        }

        func apply(planId _: UUID, token _: ApprovalToken) async throws {}
        func verify(planId _: UUID) async throws -> VerificationResult {
            throw CancellationError()
        }

        func history() async throws -> [Plan] {
            []
        }

        func undo(planId _: UUID) async throws {}
        func installedApplications() async throws -> [InstalledApplication] {
            []
        }

        func recoverableItems() async throws -> [RecoverableItem] {
            []
        }
    }

    func testAKeptOrphanIsNotTickedByTheNextScanOrBySelectAll() async {
        // Orphans are pre-selected on every scan. Without the kept list
        // taking part, keeping one would last until the next Check Again.
        let model = LeftoversModel()
        let service = Stub([leftover("/Users/me/Library/Caches/com.gone.app", .orphaned)])
        await model.load(service: service)
        let group = model.orphanedGroups[0]
        model.keptGroups = [group.id]
        XCTAssertTrue(model.selection.isEmpty)

        await model.load(service: service)
        XCTAssertTrue(model.selection.isEmpty, "A rescan does not undo a decision")
        model.selectAll(groups: model.orphanedGroups)
        XCTAssertTrue(model.selection.isEmpty)
    }
}
