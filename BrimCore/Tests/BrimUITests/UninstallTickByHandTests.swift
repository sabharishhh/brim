import BrimCore
import BrimProtocol
@testable import BrimUI
import Testing
import XCTest

/// Plans the way the service does for the one thing these tests care about:
/// an offered row becomes a step when the intent ticks it. Every intent is
/// recorded, and replies can be held back to exercise the timing.
private actor TickingStub: BrimServiceProtocol, ApprovalGranting {
    let offered: [String]
    let vetoed: [String]
    private(set) var intents: [PlanIntent] = []
    private(set) var approvals = 0
    private var held = false
    private var waiting: [CheckedContinuation<Void, any Error>] = []

    init(offered: [String], vetoed: [String] = []) {
        self.offered = offered
        self.vetoed = vetoed
    }

    func hold() {
        held = true
    }

    func pending() -> Int {
        waiting.count
    }

    /// Releases one held reply, by the order the requests arrived in.
    func release(_ index: Int) {
        waiting.remove(at: index).resume()
    }

    func fail(_ index: Int) {
        waiting.remove(at: index).resume(throwing: NotHere())
    }

    func releaseAll() {
        held = false; waiting.forEach { $0.resume() }; waiting = []
    }

    func recorded() -> [PlanIntent] {
        intents
    }

    func approvalCount() -> Int {
        approvals
    }

    func plan(intent: PlanIntent) async throws -> Plan {
        intents.append(intent)
        if held {
            try await withCheckedThrowingContinuation { waiting.append($0) }
        }
        let ticked = Set(intent.tickedByHand ?? [])
        var steps = [Step(
            index: 0, kind: .trashPath, target: "/Applications/Editor.app", targetFingerprint: nil,
            tier: .A, evidence: "The application bundle itself.", expectedBytes: 100,
            capability: .ok, reversible: true, costOfError: .medium, executionPhase: .appBundle,
            disposition: .trash
        )]
        var excluded: [ExcludedItem] = []
        for path in offered {
            if ticked.contains(path) {
                steps.append(Step(
                    index: steps.count, kind: .trashPath, target: path, targetFingerprint: nil,
                    tier: .C, evidence: "Named after the application.", expectedBytes: 1000,
                    capability: .ok, reversible: true, costOfError: .medium,
                    executionPhase: .auxiliary, disposition: .trash
                ))
            } else {
                excluded.append(ExcludedItem(
                    target: path, reason: "left unticked", evidence: "Named after the application.",
                    sizeBytes: 1000, canBeTickedByHand: true
                ))
            }
        }
        for path in vetoed {
            excluded.append(ExcludedItem(
                target: path, reason: "Shared with other installed software.",
                sizeBytes: 10, canBeTickedByHand: false
            ))
        }
        return Plan(
            planId: UUID(), createdAt: Date(), engineVersion: "t", osVersion: "t",
            intent: intent, steps: steps, excludedItems: excluded, expectedTotalBytes: 0
        )
    }

    func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalRequestReceipt {
        approvals += 1
        return .stub(planId: planId, requester: requesterIdentity)
    }

    func grantApproval(for receipt: ApprovalRequestReceipt) async throws -> ApprovalToken {
        .stub(requester: receipt.requester)
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {}
    func verify(planId: UUID) async throws -> VerificationResult {
        VerificationResult(planId: planId, expectedBytes: 0, recoveredBytes: 0, success: true)
    }

    func inspect(identity _: Identity) async throws -> Footprint {
        throw NotHere()
    }

    func explain(planId _: UUID) async throws -> String {
        throw NotHere()
    }

    func history() async throws -> [Plan] {
        []
    }

    func undo(planId _: UUID) async throws {
        throw NotHere()
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

private struct NotHere: Error {}

/// The uninstall sheet's half of ticking a row by hand.
///
/// Every change of mind builds a fresh plan, because an approval is bound to
/// one plan and `apply` rebuilds exactly that plan from its intent. Two
/// things follow, and both are tested here rather than trusted: the plan on
/// screen while the next one is being built is out of date and must not be
/// approvable, and a reply that arrives late must not replace the plan for a
/// newer choice. Either mistake means approving something other than what the
/// person is looking at.
@MainActor
final class UninstallTickByHandTests: XCTestCase {
    private let code = "/Users/me/Library/Application Support/Code"
    private let logs = "/Users/me/Library/Logs/Code"
    private let teams = "/Users/me/Library/Group Containers/UBF8T346G9.com.microsoft.teams"

    private var intent: PlanIntent {
        PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: "com.t.editor", name: "Editor"))
    }

    private func prepared(_ stub: TickingStub) async -> UninstallExecutionModel {
        let model = UninstallExecutionModel()
        await model.prepare(intent: intent, service: stub)
        return model
    }

    private func settle(_ condition: @MainActor () async -> Bool) async {
        for _ in 0 ..< 200 {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The expected planning request did not arrive.")
    }

    // MARK: - Offering and ticking

    /// **Application Support/Code**, offered and ticked.
    func testTickingARowBuildsAPlanThatRemovesIt() async {
        let stub = TickingStub(offered: [code])
        let model = await prepared(stub)
        XCTAssertEqual(model.rowsToOffer.map(\.target), [code])

        await model.setTicked(true, path: code)

        let last = await stub.recorded().last
        XCTAssertEqual(last?.tickedByHand, [code], "The choice did not reach the intent.")
        XCTAssertTrue(model.removalSteps.contains { $0.target == code })
        XCTAssertTrue(model.rowsToOffer.isEmpty, "A row being removed is still offered.")
        XCTAssertTrue(model.isTickedByHand(code))
    }

    /// Changing your mind puts it back, and the intent returns to ticking
    /// nothing, so the plan hashes exactly as one made without the sheet.
    func testUntickingPutsTheRowBackOnOffer() async {
        let stub = TickingStub(offered: [code])
        let model = await prepared(stub)

        await model.setTicked(true, path: code)
        await model.setTicked(false, path: code)

        let last = await stub.recorded().last
        XCTAssertNil(last?.tickedByHand)
        XCTAssertEqual(model.rowsToOffer.map(\.target), [code])
        XCTAssertFalse(model.removalSteps.contains { $0.target == code })
    }

    /// Two rows ticked are both carried, in a stable order so the same choice
    /// always makes the same intent.
    func testSeveralTicksTravelTogetherInAStableOrder() async {
        let stub = TickingStub(offered: [logs, code])
        let model = await prepared(stub)

        await model.setTicked(true, path: logs)
        await model.setTicked(true, path: code)

        let last = await stub.recorded().last
        XCTAssertEqual(last?.tickedByHand, [code, logs].sorted())
    }

    /// Something else on this Mac claims it, so it is not offered at all.
    func testAVetoedRowIsNotOffered() async {
        let stub = TickingStub(offered: [code], vetoed: [teams])
        let model = await prepared(stub)
        XCTAssertFalse(model.rowsToOffer.contains { $0.target == teams })
    }

    // MARK: - Approving what is on screen

    /// **The plan on screen is out of date while the next one is built.**
    /// Approving it then would approve a plan without the row the person just
    /// ticked, or with the one they just unticked.
    func testAPlanStillBeingRebuiltCannotBeApproved() async {
        let stub = TickingStub(offered: [code])
        let model = await prepared(stub)
        XCTAssertTrue(model.canAuthorize)

        await stub.hold()
        let change = Task { await model.setTicked(true, path: code) }
        await settle { await stub.pending() == 1 }

        XCTAssertTrue(model.isUpdating)
        XCTAssertFalse(model.canAuthorize, "The out-of-date plan could be approved.")
        await model.authorize(requesterIdentity: "me")
        let asked = await stub.approvalCount()
        XCTAssertEqual(asked, 0, "Approval was requested for a plan that is being replaced.")

        await stub.releaseAll()
        await change.value
        XCTAssertFalse(model.isUpdating)
        XCTAssertTrue(model.canAuthorize)
        XCTAssertTrue(model.removalSteps.contains { $0.target == code })
    }

    /// **A late reply is not the answer.** Tick, then untick, with the first
    /// plan arriving after the second: what is on screen has to be the plan
    /// for the choice the person made last.
    func testAnOlderPlanArrivingLateDoesNotReplaceTheNewerOne() async {
        let stub = TickingStub(offered: [code])
        let model = await prepared(stub)

        await stub.hold()
        let first = Task { await model.setTicked(true, path: code) }
        await settle { await stub.pending() == 1 }
        let second = Task { await model.setTicked(false, path: code) }
        await settle { await stub.pending() == 2 }

        await stub.release(1) // the untick answers first
        await second.value
        await stub.release(0) // then the tick, late
        await first.value

        XCTAssertFalse(
            model.removalSteps.contains { $0.target == code },
            "The plan for an earlier choice replaced the one the person made last."
        )
        XCTAssertNil(model.plan?.intent.tickedByHand)
        XCTAssertFalse(model.isUpdating)
        XCTAssertTrue(model.canAuthorize)
    }

    /// Once the removal has started, the plan is what it is.
    func testNothingCanBeTickedOnceTheRemovalHasStarted() async {
        let stub = TickingStub(offered: [code])
        let model = await prepared(stub)
        await model.authorize(requesterIdentity: "me")
        let before = await stub.recorded().count

        await model.setTicked(true, path: code)

        let after = await stub.recorded().count
        XCTAssertEqual(before, after, "A new plan was built after the removal had run.")
        XCTAssertFalse(model.isTickedByHand(code))
    }
}

@MainActor
struct UninstallSelectionFailureTests {
    private let path = "/Users/me/Library/Application Support/Code"
    private var intent: PlanIntent {
        PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: "com.t.editor", name: "Editor"))
    }

    private func waitForRequest(_ stub: TickingStub) async throws {
        for _ in 0 ..< 200 {
            if await stub.pending() == 1 {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The expected planning request did not arrive.")
        throw NotHere()
    }

    @Test func failedRebuildCannotApproveTheOldPlan() async throws {
        let stub = TickingStub(offered: [path])
        let model = UninstallExecutionModel()
        await model.prepare(intent: intent, service: stub)
        await stub.hold()
        let change = Task { await model.setTicked(true, path: path) }
        try await waitForRequest(stub)
        await stub.fail(0)
        await change.value

        guard case .failed = model.phase else {
            Issue.record("A failed rebuild should report failure.")
            return
        }
        #expect(!model.canAuthorize)
        await model.authorize(requesterIdentity: "me")
        #expect(await stub.approvalCount() == 0)
    }

    @Test(arguments: [false, true])
    func oldPreparationCannotReplaceANewerSheet(fails: Bool) async throws {
        let oldService = TickingStub(offered: [path])
        let newService = TickingStub(offered: [])
        let model = UninstallExecutionModel()
        await oldService.hold()
        let old = Task { await model.prepare(intent: intent, service: oldService) }
        try await waitForRequest(oldService)
        await model.prepare(intent: intent, service: newService)
        let currentID = model.plan?.planId
        if fails {
            await oldService.fail(0)
        } else {
            await oldService.release(0)
        }
        await old.value

        #expect(model.phase == .ready)
        #expect(model.plan?.planId == currentID)
        #expect(model.rowsToOffer.isEmpty)
    }

    @Test func onlyOfferedRowsCanBeTickedAndRepeatedTicksDoNothing() async {
        let vetoed = "/Users/me/Library/Group Containers/shared"
        let stub = TickingStub(offered: [path], vetoed: [vetoed])
        let model = UninstallExecutionModel()
        await model.prepare(intent: intent, service: stub)
        await model.setTicked(true, path: vetoed)
        await model.setTicked(true, path: "/Users/me/Documents/Thesis.md")
        #expect(model.tickedByHand.isEmpty)
        #expect(await stub.recorded().count == 1)
        await model.setTicked(true, path: path)
        await model.setTicked(true, path: path)
        #expect(await stub.recorded().count == 2)
    }
}
