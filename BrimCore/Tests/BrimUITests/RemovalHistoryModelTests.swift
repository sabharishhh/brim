import XCTest
import BrimCore
import BrimProtocol
@testable import BrimUI

/// A service that answers from whatever the test set up, and records calls.
private actor HistoryStub: BrimServiceProtocol {
    var plans: [Plan]
    var recoverable: [RecoverableItem]
    var undoError: Error?
    private(set) var undoCalls: [UUID] = []

    init(plans: [Plan], recoverable: [RecoverableItem], undoError: Error? = nil) {
        self.plans = plans
        self.recoverable = recoverable
        self.undoError = undoError
    }

    func history() async throws -> [Plan] { plans }
    func recoverableItems() async throws -> [RecoverableItem] { recoverable }

    func undo(planId: UUID) async throws {
        undoCalls.append(planId)
        if let undoError { throw undoError }
        // A successful undo puts the item back, so it stops being recoverable.
        recoverable.removeAll { $0.planId == planId }
    }

    func calls() -> [UUID] { undoCalls }

    func inspect(identity: Identity) async throws -> Footprint { throw Stub.unimplemented }
    func plan(intent: PlanIntent) async throws -> Plan { throw Stub.unimplemented }
    func explain(planId: UUID) async throws -> String { throw Stub.unimplemented }
    func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalRequestReceipt { throw Stub.unimplemented }
    func apply(planId: UUID, token: ApprovalToken) async throws { throw Stub.unimplemented }
    func verify(planId: UUID) async throws -> VerificationResult { throw Stub.unimplemented }
    func installedApplications() async throws -> [InstalledApplication] { [] }
    func leftovers() async throws -> [Leftover] { [] }
}

private enum Stub: Error, LocalizedError {
    case unimplemented
    case refused
    var errorDescription: String? {
        switch self {
        case .unimplemented: return "unimplemented"
        case .refused: return "No longer in the Trash, so it cannot be restored: Thing."
        }
    }
}

private func makePlan(name: String, disposition: StepDisposition, createdAt: Date = Date()) -> Plan {
    let step = Step(
        index: 0,
        kind: .trashPath,
        target: "/tmp/\(name)",
        targetFingerprint: nil,
        tier: .A,
        evidence: "test",
        expectedBytes: 1024,
        capability: .ok,
        reversible: disposition == .trash,
        costOfError: disposition == .trash ? .medium : .low,
        executionPhase: .auxiliary,
        disposition: disposition
    )
    return Plan(
        planId: UUID(),
        createdAt: createdAt,
        engineVersion: "test",
        osVersion: "test",
        intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: nil, name: name)),
        steps: [step],
        excludedItems: [],
        expectedTotalBytes: 1024
    )
}

@MainActor
final class RemovalHistoryModelTests: XCTestCase {

    func testMarksOnlyItemsStillInTheTrashAsUndoable() async throws {
        let trashed = makePlan(name: "Settings", disposition: .trash)
        let permanent = makePlan(name: "Cache", disposition: .delete)
        let stub = HistoryStub(
            plans: [trashed, permanent],
            recoverable: [RecoverableItem(planId: trashed.planId, name: "Settings", bytes: 1024, removedAt: Date())]
        )

        let model = RemovalHistoryModel()
        await model.load(service: stub)

        XCTAssertEqual(model.records.count, 2)
        let settings = try XCTUnwrap(model.records.first { $0.name == "Settings" })
        XCTAssertTrue(settings.canUndo)
        XCTAssertNil(settings.unavailableReason)
    }

    func testExplainsWhyAPermanentRemovalCannotBeUndone() async throws {
        let permanent = makePlan(name: "Cache", disposition: .delete)
        let stub = HistoryStub(plans: [permanent], recoverable: [])

        let model = RemovalHistoryModel()
        await model.load(service: stub)

        let record = try XCTUnwrap(model.records.first)
        XCTAssertFalse(record.canUndo)
        XCTAssertEqual(record.unavailableReason, "Deleted permanently")
    }

    func testExplainsWhyAnEmptiedTrashCannotBeUndone() async throws {
        // Trashed, so the plan is reversible in principle, but no longer
        // listed as recoverable — the user emptied the Trash.
        let trashed = makePlan(name: "Settings", disposition: .trash)
        let stub = HistoryStub(plans: [trashed], recoverable: [])

        let model = RemovalHistoryModel()
        await model.load(service: stub)

        let record = try XCTUnwrap(model.records.first)
        XCTAssertFalse(record.canUndo)
        XCTAssertEqual(record.unavailableReason, "No longer in the Trash")
    }

    func testUndoingRemovesTheItemFromTheUndoableSet() async throws {
        let trashed = makePlan(name: "Settings", disposition: .trash)
        let stub = HistoryStub(
            plans: [trashed],
            recoverable: [RecoverableItem(planId: trashed.planId, name: "Settings", bytes: 1024, removedAt: Date())]
        )

        let model = RemovalHistoryModel()
        await model.load(service: stub)
        let record = try XCTUnwrap(model.records.first)
        XCTAssertTrue(record.canUndo)

        await model.undo(record)

        let calls = await stub.calls()
        XCTAssertEqual(calls, [trashed.planId])
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.records.first?.canUndo, false, "Restored items are no longer undoable")
        XCTAssertTrue(model.undoingPlanIds.isEmpty)
    }

    func testAFailedUndoSurfacesTheServiceSentence() async throws {
        let trashed = makePlan(name: "Settings", disposition: .trash)
        let stub = HistoryStub(
            plans: [trashed],
            recoverable: [RecoverableItem(planId: trashed.planId, name: "Settings", bytes: 1024, removedAt: Date())],
            undoError: Stub.refused
        )

        let model = RemovalHistoryModel()
        await model.load(service: stub)
        await model.undo(try XCTUnwrap(model.records.first))

        XCTAssertEqual(model.errorMessage, "No longer in the Trash, so it cannot be restored: Thing.")
        XCTAssertTrue(model.undoingPlanIds.isEmpty, "The row must not stay stuck in a spinner")
    }

    func testRecordsAreNewestFirst() async {
        let old = makePlan(name: "Older", disposition: .trash, createdAt: Date(timeIntervalSince1970: 1000))
        let new = makePlan(name: "Newer", disposition: .trash, createdAt: Date(timeIntervalSince1970: 2000))
        let stub = HistoryStub(plans: [old, new], recoverable: [])

        let model = RemovalHistoryModel()
        await model.load(service: stub)

        XCTAssertEqual(model.records.map(\.name), ["Newer", "Older"])
    }
}
