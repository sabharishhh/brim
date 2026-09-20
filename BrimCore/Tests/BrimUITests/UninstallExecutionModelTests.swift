import XCTest
import BrimCore
import BrimProtocol
@testable import BrimUI

private actor UninstallStub: BrimServiceProtocol {
    var planToReturn: Plan?
    var planError: Error?
    var approvalError: Error?
    var applyError: Error?
    var verifyResult: VerificationResult?
    var verifyError: Error?

    private(set) var approvals = 0
    private(set) var applies = 0
    private(set) var verifies = 0

    init(plan: Plan? = nil, planError: Error? = nil, approvalError: Error? = nil,
         applyError: Error? = nil, verifyResult: VerificationResult? = nil, verifyError: Error? = nil) {
        self.planToReturn = plan
        self.planError = planError
        self.approvalError = approvalError
        self.applyError = applyError
        self.verifyResult = verifyResult
        self.verifyError = verifyError
    }

    func plan(intent: PlanIntent) async throws -> Plan {
        if let planError { throw planError }
        return planToReturn!
    }

    func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalToken {
        approvals += 1
        if let approvalError { throw approvalError }
        return ApprovalToken(token: "test-token")
    }

    func apply(planId: UUID, token: ApprovalToken) async throws {
        applies += 1
        if let applyError { throw applyError }
    }

    func verify(planId: UUID) async throws -> VerificationResult {
        verifies += 1
        if let verifyError { throw verifyError }
        return verifyResult!
    }

    func counts() -> (approvals: Int, applies: Int, verifies: Int) { (approvals, applies, verifies) }

    func inspect(identity: Identity) async throws -> Footprint { throw Oops.no }
    func explain(planId: UUID) async throws -> String { throw Oops.no }
    func history() async throws -> [Plan] { [] }
    func undo(planId: UUID) async throws { throw Oops.no }
    func dumpBTM() async throws -> String { "" }
    func installedApplications() async throws -> [InstalledApplication] { [] }
    func leftovers() async throws -> [Leftover] { [] }
    func recoverableItems() async throws -> [RecoverableItem] { [] }
    func scanDuplicates(in directory: URL) async throws -> [DuplicateGroup] { [] }
}

private enum Oops: Error, LocalizedError {
    case no
    case refused
    var errorDescription: String? { self == .refused ? "User cancelled authentication." : "no" }
}

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

        guard case .verified(let result) = model.phase else {
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

    func testAFailedVerificationSaysTheRemovalHappenedAnyway() async {
        // The distinction matters: the files are gone but the check could not
        // run, which is different from the removal having failed.
        let plan = makePlan([step(0, kind: .trashPath, target: "/a")])
        let stub = UninstallStub(plan: plan, verifyError: Oops.no)
        let model = UninstallExecutionModel()

        await model.prepare(intent: intent, service: stub)
        await model.authorize(requesterIdentity: "tester")

        guard case .failed(let message) = model.phase else {
            return XCTFail("Expected failure, got \(model.phase)")
        }
        XCTAssertTrue(message.hasPrefix("Removed, but verification could not run"), message)
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
        XCTAssertTrue(model.clearsPrivacyGrants)
    }

    func testAFailureToPlanIsSurfacedAndBlocksAuthorization() async {
        let stub = UninstallStub(planError: Oops.no)
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
