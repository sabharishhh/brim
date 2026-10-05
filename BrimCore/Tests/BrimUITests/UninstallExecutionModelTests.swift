import BrimCore
import BrimProtocol
@testable import BrimUI
import Testing
import XCTest

private func step(_ index: Int, kind: StepKind, target: String) -> Step {
    Step(index: index, kind: kind, target: target, targetFingerprint: nil, tier: .A,
         evidence: "because", expectedBytes: 100, capability: .ok, reversible: true,
         costOfError: .medium, executionPhase: kind == .resetPrivacyGrants ? .privacyReset : .auxiliary,
         disposition: .trash)
}

private func makePlan(_ steps: [Step]) -> Plan {
    Plan(planId: UUID(), createdAt: Date(), engineVersion: "t", osVersion: "t",
         intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: "com.t.app", name: "App")),
         steps: steps, excludedItems: [], expectedTotalBytes: 100)
}

private let intent = PlanIntent(
    type: .uninstall,
    subjectIdentity: Identity(bundleID: "com.t.app", name: "App")
)

@MainActor
final class UninstallExecutionModelTests: XCTestCase {
    func testAPlannedUninstallIsReadyAndNotYetApplied() async {
        let plan = makePlan([step(0, kind: .trashPath, target: "/a")])
        let stub = UninstallStub(plan: plan)
        let model = UninstallExecutionModel()

        await model.prepare(intent: intent, service: stub)

        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.canAuthorize)
        let counts = await stub.counts()
        XCTAssertEqual(counts.applies, 0, "Planning must not apply anything")
    }

    func testAuthorizingAppliesOnceAndThenVerifies() async {
        let plan = makePlan([step(0, kind: .trashPath, target: "/a")])
        let verification = VerificationResult(planId: plan.planId, expectedBytes: 100,
                                              recoveredBytes: 100, success: true, reason: nil)
        let stub = UninstallStub(plan: plan, verifyResult: verification)
        let model = UninstallExecutionModel()

        await model.prepare(intent: intent, service: stub)
        await model.authorize(requesterIdentity: "tester")

        let counts = await stub.counts()
        XCTAssertEqual(counts.approvals, 1, "One approval for the whole plan")
        XCTAssertEqual(counts.applies, 1)
        XCTAssertEqual(counts.verifies, 1, "The claim has to be checked, not assumed")
        XCTAssertEqual(model.phase, .verified(verification))
    }

    func testAnIncompleteRemovalIsReportedRatherThanCalledSuccess() async {
        let plan = makePlan([step(0, kind: .trashPath, target: "/a")])
        let verification = VerificationResult(planId: plan.planId, expectedBytes: 100,
                                              recoveredBytes: 0, success: false,
                                              reason: "1 targets still remain.")
        let stub = UninstallStub(plan: plan, verifyResult: verification)
        let model = UninstallExecutionModel()

        await model.prepare(intent: intent, service: stub)
        await model.authorize(requesterIdentity: "tester")

        guard case let .verified(result) = model.phase else {
            return XCTFail("Expected a verified phase carrying the failure, got \(model.phase)")
        }
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.reason, "1 targets still remain.")
    }

    func testADeclinedAuthorizationDoesNotApply() async {
        let plan = makePlan([step(0, kind: .trashPath, target: "/a")])
        let stub = UninstallStub(plan: plan, approvalError: Oops.refused)
        let model = UninstallExecutionModel()

        await model.prepare(intent: intent, service: stub)
        await model.authorize(requesterIdentity: "tester")

        let counts = await stub.counts()
        XCTAssertEqual(counts.applies, 0, "Refusing authentication must not remove anything")
        XCTAssertEqual(model.phase, .failed("User cancelled authentication."))
    }

    /// The files are gone and the check could not run, which is a different
    /// outcome from the removal having failed.
    ///
    /// This was already the intent, and the wording carried it: the phase
    /// was `.failed("Removed, but verification could not run: …")`. The
    /// sheets then drew every `.failed` in red under the heading "Stopped",
    /// so somebody whose uninstall had gone through was told it had been
    /// stopped, with the sentence that said otherwise underneath it. A
    /// distinction that only exists inside a string is a distinction the
    /// interface cannot act on, so it has its own case now.
    func testAFailedVerificationIsNotReportedAsAFailedRemoval() async {
        let plan = makePlan([step(0, kind: .trashPath, target: "/a")])
        let stub = UninstallStub(plan: plan, verifyError: Oops.unavailable)
        let model = UninstallExecutionModel()

        await model.prepare(intent: intent, service: stub)
        await model.authorize(requesterIdentity: "tester")

        guard case let .appliedButUnverified(reason) = model.phase else {
            return XCTFail("Expected appliedButUnverified, got \(model.phase)")
        }
        XCTAssertEqual(reason, "no", "The underlying reason travels, unwrapped")

        let counts = await stub.counts()
        XCTAssertEqual(counts.applies, 1, "The removal did happen")
    }

    func testAnApprovalThatFailsIsAFailureAndAppliesNothing() async {
        // The other side of the case above: here nothing ran, so this one
        // really is `.failed` and the sheet's red heading is correct.
        let plan = makePlan([step(0, kind: .trashPath, target: "/a")])
        let stub = UninstallStub(plan: plan, applyError: Oops.unavailable)
        let model = UninstallExecutionModel()

        await model.prepare(intent: intent, service: stub)
        await model.authorize(requesterIdentity: "tester")

        guard case .failed = model.phase else {
            return XCTFail("Expected failed, got \(model.phase)")
        }
        let counts = await stub.counts()
        XCTAssertEqual(counts.verifies, 0, "Nothing to verify when nothing was applied")
    }

    func testBookkeepingStepsAreNotCountedAsLocations() async {
        let plan = makePlan([
            step(0, kind: .resetPrivacyGrants, target: "com.t.app"),
            step(1, kind: .unloadLaunchdJob, target: "/Library/LaunchAgents/x.plist"),
            step(2, kind: .removeLaunchdPlist, target: "/Library/LaunchAgents/x.plist"),
            step(3, kind: .trashPath, target: "/Applications/App.app")
        ])
        let stub = UninstallStub(plan: plan)
        let model = UninstallExecutionModel()

        await model.prepare(intent: intent, service: stub)

        XCTAssertEqual(model.removalSteps.count, 2, "A privacy reset and an unload are not locations")
    }

    func testAFailureToPlanIsSurfacedAndBlocksAuthorization() async {
        let stub = UninstallStub(planError: Oops.unavailable)
        let model = UninstallExecutionModel()

        await model.prepare(intent: intent, service: stub)

        XCTAssertEqual(model.phase, .failed("no"))
        XCTAssertFalse(model.canAuthorize)
    }

    func testAnEmptyPlanCannotBeAuthorized() async {
        let stub = UninstallStub(plan: makePlan([]))
        let model = UninstallExecutionModel()

        await model.prepare(intent: intent, service: stub)

        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.canAuthorize, "Nothing to remove means nothing to approve")
    }
}

/// Several apps in one review are the single removal run once per app,
/// through the same approval and check, and one app that cannot be planned
/// does not stop the rest.
private actor BatchStub: BrimServiceProtocol, ApprovalGranting {
    private(set) var applied: [UUID] = []
    private var plans: [UUID: String] = [:]

    func plan(intent: PlanIntent) async throws -> Plan {
        if intent.subjectIdentity.bundleID == "com.t.bad" {
            throw Oops.unavailable
        }
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "t", osVersion: "t", intent: intent,
                        steps: [step(0, kind: .trashPath, target: "/\(intent.subjectIdentity.name)")],
                        excludedItems: [], expectedTotalBytes: 100)
        plans[plan.planId] = intent.subjectIdentity.name
        return plan
    }

    func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalRequestReceipt {
        .stub(planId: planId, requester: requesterIdentity)
    }

    func grantApproval(for receipt: ApprovalRequestReceipt) async throws -> ApprovalToken {
        .stub(requester: receipt.requester)
    }

    func apply(planId: UUID, token _: ApprovalToken) async throws {
        applied.append(planId)
    }

    func verify(planId: UUID) async throws -> VerificationResult {
        VerificationResult(planId: planId, expectedBytes: 100, recoveredBytes: 100, success: true)
    }

    func appliedNames() -> [String] {
        applied.compactMap { plans[$0] }
    }

    func inspect(identity _: Identity) async throws -> Footprint {
        throw Oops.unavailable
    }

    func explain(planId _: UUID) async throws -> String {
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

@MainActor
final class BatchRemovalModelTests: XCTestCase {
    private func app(_ name: String, _ id: String, protected: Bool = false) -> InstalledApplication {
        InstalledApplication(identity: Identity(bundleID: id, name: name),
                             url: URL(fileURLWithPath: "/Applications/\(name).app"),
                             bundleSizeBytes: 1, isSystemProtected: protected)
    }

    func testEachAppIsItsOwnPlanAndAFailureStopsOnlyItself() async {
        let stub = BatchStub()
        let model = BatchRemovalModel()
        let alpha = app("Alpha", "com.t.alpha")
        await model.prepare([alpha, app("Bad", "com.t.bad"), app("Beta", "com.t.beta"), alpha,
                             app("Safari", "com.apple.Safari", protected: true)], service: stub)
        XCTAssertEqual(model.entries.map(\.app.name), ["Alpha", "Bad", "Beta"], "one plan per app, never macOS's")
        XCTAssertEqual(model.ready.map(\.app.name), ["Alpha", "Beta"])

        await model.removeAll(requesterIdentity: "tester")
        let applied = await stub.appliedNames()
        XCTAssertEqual(applied, ["Alpha", "Beta"])
        XCTAssertTrue(model.isFinished)
        XCTAssertTrue(model.entries.filter { $0.app.name != "Bad" }.allSatisfy {
            if case .verified = $0.removal.phase {
                true
            } else {
                false
            }
        })
    }
}

@Suite("Removal capacity explanations")
@MainActor
struct RemovalCapacityExplanationTests {
    /// A refused capacity read used to become zero and trigger a confident
    /// snapshot explanation. A failed removal made the same false claim.
    @Test("Unmeasured or failed removals do not claim delayed recovery",
          arguments: [(false, Optional(true)), (true, Optional(false)), (true, nil)])
    func unavailableCapacity(success: Bool, measured: Bool?) async {
        let model = await completedModel(success: success, measured: measured)
        #expect(model.spaceExplanation == nil)
    }

    @Test("A measured shortfall describes possible causes")
    func measuredShortfall() async {
        let model = await completedModel(success: true, measured: true)
        #expect(model.spaceExplanation?.contains("account for it") == true)
    }

    private func completedModel(success: Bool, measured: Bool?) async -> UninstallExecutionModel {
        let target = Step(index: 0, kind: .trashPath, target: "/fixture/build",
                          targetFingerprint: nil, tier: .A, evidence: "Compiled output",
                          expectedBytes: 200_000_000, capability: .ok, reversible: false,
                          costOfError: .low, executionPhase: .auxiliary, disposition: .delete)
        let plan = makePlan([target])
        let verification = VerificationResult(planId: plan.planId, expectedBytes: 200_000_000,
                                              recoveredBytes: 0, success: success, reason: nil,
                                              freeSpaceMeasured: measured)
        let service = UninstallStub(plan: plan, verifyResult: verification)
        let model = UninstallExecutionModel()
        await model.prepare(intent: plan.intent, service: service)
        await model.authorize(requesterIdentity: "tester")
        return model
    }
}
