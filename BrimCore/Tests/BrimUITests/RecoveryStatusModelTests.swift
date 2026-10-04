import BrimCore
import BrimProtocol
@testable import BrimUI
import Foundation
import XCTest

@MainActor
final class RecoveryStatusModelTests: XCTestCase {
    func testExplicitRefreshRechecksTheTrashAndAgreesWithJournal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ["First", "Second"].map { folder.appendingPathComponent($0) }
        for file in files {
            try Data("saved settings".utf8).write(to: file)
        }
        let service = RecoveryStatusFixture(files: files)
        let recovery = RecoveryStatusModel()
        let history = RemovalHistoryModel()
        await recovery.refresh(service: service)
        let order = await service.refreshOrder()
        XCTAssertEqual(order, ["recoverability", "registrations"])
        await history.load(service: service)
        XCTAssertTrue(recovery.isAvailable)
        XCTAssertEqual(recovery.items.count, 2)
        XCTAssertEqual(history.records.filter(\.canUndo).count, 2)

        // Home kept two recoverable removals after Finder emptied the Trash
        // because Check Again never re-read its recovery model.
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
        await recovery.refresh(service: service)
        await history.reload()
        XCTAssertTrue(recovery.isAvailable)
        XCTAssertTrue(recovery.isEmpty)
        XCTAssertEqual(recovery.totalBytes, 0)
        XCTAssertTrue(history.records.allSatisfy { !$0.canUndo })
    }

    func testFailedRefreshMakesThePreviousPositiveCountUnavailable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Saved")
        try Data("saved settings".utf8).write(to: file)
        let service = RecoveryStatusFixture(files: [file])
        let recovery = RecoveryStatusModel()
        await recovery.refresh(service: service)
        XCTAssertTrue(recovery.isAvailable)
        XCTAssertEqual(recovery.items.count, 1)

        await service.refuseReads(true)
        await recovery.refresh(service: service)
        XCTAssertFalse(recovery.isAvailable)
        XCTAssertEqual(recovery.items.count, 1, "A failed read does not establish an empty Trash.")

        await service.refuseReads(false)
        try FileManager.default.removeItem(at: file)
        await recovery.refresh(service: service)
        XCTAssertTrue(recovery.isAvailable)
        XCTAssertTrue(recovery.isEmpty)
    }
}

private actor RecoveryStatusFixture: BrimServiceProtocol {
    private let files: [URL]
    private let plans: [Plan]
    private var refused = false
    private var order: [String] = []

    init(files: [URL]) {
        self.files = files
        plans = files.map { file in
            Plan(planId: UUID(), createdAt: Date(), engineVersion: "fixture", osVersion: "fixture",
                 intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(name: file.lastPathComponent)),
                 steps: [Step(index: 0, kind: .trashPath, target: file.path, targetFingerprint: nil,
                              tier: .A, evidence: "Fixture", expectedBytes: 14, capability: .ok,
                              reversible: true, costOfError: .medium, executionPhase: .auxiliary,
                              disposition: .trash)], excludedItems: [], expectedTotalBytes: 14)
        }
    }

    func refuseReads(_ refused: Bool) {
        self.refused = refused
    }

    func refreshOrder() -> [String] {
        order
    }

    func history() async throws -> [Plan] {
        plans
    }

    func recoverableItems() async throws -> [RecoverableItem] {
        order.append("recoverability")
        if refused {
            throw CocoaError(.fileReadNoPermission)
        }
        return zip(files, plans).compactMap { file, plan in
            guard PathExistence.exists(at: file) else { return nil }
            return RecoverableItem(planId: plan.planId, name: plan.intent.subjectIdentity.name,
                                   bytes: plan.expectedTotalBytes, removedAt: plan.createdAt)
        }
    }

    func reconcileRegistrations() async {
        order.append("registrations")
    }

    func inspect(identity _: Identity) async throws -> Footprint {
        throw CocoaError(.featureUnsupported)
    }

    func plan(intent _: PlanIntent) async throws -> Plan {
        throw CocoaError(.featureUnsupported)
    }

    func explain(planId _: UUID) async throws -> String {
        throw CocoaError(.featureUnsupported)
    }

    func requestApproval(planId _: UUID, requesterIdentity _: String) async throws -> ApprovalRequestReceipt {
        throw CocoaError(.featureUnsupported)
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {
        throw CocoaError(.featureUnsupported)
    }

    func verify(planId _: UUID) async throws -> VerificationResult {
        throw CocoaError(.featureUnsupported)
    }

    func installedApplications() async throws -> [InstalledApplication] {
        []
    }

    func leftovers() async throws -> [Leftover] {
        []
    }

    func undo(planId _: UUID) async throws {
        throw CocoaError(.featureUnsupported)
    }
}
