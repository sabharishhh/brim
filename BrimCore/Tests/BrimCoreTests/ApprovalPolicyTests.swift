import XCTest
@testable import BrimCore

/// When Brim interrupts a human, and — just as importantly — when it does
/// not. Both directions are tested: a policy that never prompts is as wrong
/// as one that always does, and the second failure is the quieter one,
/// because a user asked constantly learns to approve without reading.
final class ApprovalPolicyTests: XCTestCase {

    private func step(
        _ index: Int,
        kind: StepKind = .trashPath,
        disposition: StepDisposition = .trash,
        cost: CostOfError = .medium,
        phase: ExecutionPhase = .auxiliary
    ) -> Step {
        Step(
            index: index, kind: kind, target: "/tmp/x\(index)", targetFingerprint: nil,
            tier: .A, evidence: "because", expectedBytes: 10, capability: .ok,
            reversible: disposition == .trash, costOfError: cost,
            executionPhase: phase, disposition: disposition
        )
    }

    /// The step every uninstall carries, and the bundle removal beside it.
    private func privacyGrants() -> Step {
        Step(
            index: 0, kind: .resetPrivacyGrants, target: "com.t.app", targetFingerprint: nil,
            tier: .A, evidence: "clears grants", expectedBytes: 0, capability: .ok,
            reversible: false, costOfError: .medium,
            executionPhase: .privacyReset, disposition: .delete
        )
    }

    private func bundleRemoval(_ index: Int = 1) -> Step {
        Step(
            index: index, kind: .trashPath, target: "/Applications/TestApp.app",
            targetFingerprint: nil, tier: .A, evidence: "the app", expectedBytes: 100,
            capability: .ok, reversible: true, costOfError: .medium,
            executionPhase: .appBundle, disposition: .trash
        )
    }

    private func plan(_ steps: [Step], name: String = "TestApp") -> Plan {
        Plan(
            planId: UUID(), createdAt: Date(), engineVersion: "t", osVersion: "t",
            intent: PlanIntent(type: .uninstall,
                               subjectIdentity: Identity(bundleID: "com.t.app", name: name)),
            steps: steps, excludedItems: [], expectedTotalBytes: 10
        )
    }

    private let policy = ApprovalPolicy()

    // MARK: - Does not prompt

    func testTrashingIsNotWorthInterruptingAnyoneFor() {
        // Finder does not ask for a fingerprint to move a file to the bin,
        // and neither should this. Undo exists.
        let requirement = policy.requirement(
            for: plan([step(0), step(1)]), lastAuthenticated: nil
        )
        XCTAssertFalse(requirement.needsPrompt)
    }

    func testDeletingARecreatableCacheDoesNotPrompt() {
        // Permanent, but costless: the cache comes back. Prompting here is
        // exactly how a user is trained to approve without reading.
        let requirement = policy.requirement(
            for: plan([step(0, disposition: .delete, cost: .low)]),
            lastAuthenticated: nil
        )
        XCTAssertFalse(requirement.needsPrompt)
    }

    func testAnEmptyPlanAsksForNothing() {
        XCTAssertFalse(policy.requirement(for: plan([]), lastAuthenticated: nil).needsPrompt)
    }

    // MARK: - Prompts

    func testPermanentlyDeletingSomethingThatMattersPrompts() {
        let requirement = policy.requirement(
            for: plan([step(0, disposition: .delete, cost: .medium)]),
            lastAuthenticated: nil
        )
        XCTAssertTrue(requirement.needsPrompt)
        guard case .humanPresence(let reason) = requirement else { return XCTFail() }
        XCTAssertTrue(reason.contains("cannot be undone"), reason)
        // macOS prefixes "Brim is trying to", so the reason has to read as
        // a continuation of that sentence.
        XCTAssertEqual(reason.first?.isLowercase, true, "Reads as 'Brim is trying to \(reason)'")
        XCTAssertFalse(reason.hasSuffix("."), "macOS adds its own full stop")
    }

    func testClearingPrivacyGrantsOnTheirOwnPrompts() {
        // tccutil cannot be walked back, and here the application stays and
        // simply loses its permissions, so there is something to lose.
        let requirement = policy.requirement(
            for: plan([privacyGrants(), step(1)]), lastAuthenticated: nil
        )
        XCTAssertTrue(requirement.needsPrompt)
        guard case .humanPresence(let reason) = requirement else { return XCTFail() }
        XCTAssertTrue(reason.contains("privacy permissions"), reason)
        XCTAssertTrue(reason.contains("TestApp"), "The prompt must name what is being removed")
    }

    /// Every uninstall of every application with an identifier emits a
    /// `resetPrivacyGrants` step, and it was counted as worth interrupting
    /// for, so the product's main action always cost a fingerprint. Nothing
    /// was being protected: the grant is a permission macOS holds for a
    /// bundle that is going away in the same plan, it is inert the moment the
    /// bundle is gone, and declining the prompt would not have kept it,
    /// because the uninstall proceeds either way.
    func testAnOrdinaryUninstallDoesNotAskForAFingerprint() {
        let uninstall = plan([privacyGrants(), bundleRemoval(), step(2)])
        let requirement = policy.requirement(for: uninstall, lastAuthenticated: nil)

        XCTAssertFalse(
            requirement.needsPrompt,
            "Removing an application and the permissions that only meant "
            + "anything while it was installed is one reversible action"
        )
    }

    func testAnUninstallThatAlsoDestroysSomethingStillPrompts() {
        // The grants are excused; a permanent deletion beside them is not,
        // so the exemption must not swallow the rest of the plan.
        let uninstall = plan([
            privacyGrants(), bundleRemoval(),
            step(2, disposition: .delete, cost: .high)
        ])
        XCTAssertTrue(policy.requirement(for: uninstall, lastAuthenticated: nil).needsPrompt)
    }

    func testForgettingAReceiptIsNotDescribedAsDeletingAFile() {
        // pkgutil --forget deletes nothing. Calling it "permanently delete 1
        // item" in the system prompt is the sort of small inaccuracy that
        // teaches somebody the prompt is not worth reading.
        let receipt = Step(
            index: 0, kind: .forgetReceipt, target: "com.t.pkg", targetFingerprint: nil,
            tier: .A, evidence: "receipt", expectedBytes: 0, capability: .needsHelper,
            reversible: false, costOfError: .medium,
            executionPhase: .registration, disposition: .delete
        )
        let requirement = policy.requirement(
            for: plan([receipt, bundleRemoval()]), lastAuthenticated: nil
        )
        XCTAssertTrue(requirement.needsPrompt, "A receipt cannot be rebuilt")
        guard case .humanPresence(let reason) = requirement else { return XCTFail() }
        XCTAssertTrue(reason.contains("installer record"), reason)
        XCTAssertFalse(reason.contains("permanently delete"), reason)
    }

    func testRetractingARegistrationIsNotDestruction() {
        // Undo re-registers the bundle, so this is not something to
        // interrupt anyone for.
        let unregister = Step(
            index: 0, kind: .unregisterLaunchServices, target: "/Applications/T.app",
            targetFingerprint: nil, tier: .A, evidence: "retracts", expectedBytes: 0,
            capability: .ok, reversible: false, costOfError: .low,
            executionPhase: .registration, disposition: .delete
        )
        XCTAssertFalse(StepKind.unregisterLaunchServices.destroysWithoutRecovery)
        XCTAssertFalse(policy.requirement(for: plan([unregister]), lastAuthenticated: nil).needsPrompt)
    }

    // MARK: - The grace window

    func testProvingPresenceOnceCoversTheNextFewMinutes() {
        // Clearing three applications in a row is one decision, not three.
        let destructive = plan([step(0, disposition: .delete, cost: .high)])
        let now = Date()
        let requirement = policy.requirement(
            for: destructive,
            lastAuthenticated: now.addingTimeInterval(-60),
            now: now
        )
        XCTAssertFalse(requirement.needsPrompt)
        guard case .alreadyGiven(let because) = requirement else { return XCTFail() }
        XCTAssertTrue(because.contains("a moment ago"), because)
    }

    func testTheGraceWindowExpires() {
        let destructive = plan([step(0, disposition: .delete, cost: .high)])
        let now = Date()
        XCTAssertTrue(
            policy.requirement(
                for: destructive,
                lastAuthenticated: now.addingTimeInterval(-301),
                now: now
            ).needsPrompt,
            "Five minutes on, presence has to be proved again"
        )
    }

    func testAClockMovedBackwardsDoesNotGrantAnUnendingWindow() {
        // A timestamp in the future would otherwise satisfy the window for
        // as long as it stayed there.
        let destructive = plan([step(0, disposition: .delete, cost: .high)])
        let now = Date()
        XCTAssertTrue(
            policy.requirement(
                for: destructive,
                lastAuthenticated: now.addingTimeInterval(600),
                now: now
            ).needsPrompt
        )
    }

    func testTheWindowNeverCreatesAPromptThatWasNotNeeded() {
        // A reversible plan is not prompted for whether or not anyone has
        // authenticated recently.
        let reversible = plan([step(0)])
        XCTAssertFalse(policy.requirement(for: reversible, lastAuthenticated: nil).needsPrompt)
        XCTAssertFalse(
            policy.requirement(for: reversible, lastAuthenticated: Date.distantPast).needsPrompt
        )
    }
}
