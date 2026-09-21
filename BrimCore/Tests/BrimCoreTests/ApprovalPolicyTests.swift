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
        cost: CostOfError = .medium
    ) -> Step {
        Step(
            index: index, kind: kind, target: "/tmp/x\(index)", targetFingerprint: nil,
            tier: .A, evidence: "because", expectedBytes: 10, capability: .ok,
            reversible: disposition == .trash, costOfError: cost,
            executionPhase: .auxiliary, disposition: disposition
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

    func testClearingPrivacyGrantsPrompts() {
        // tccutil cannot be walked back, and this is the step that makes an
        // application uninstall worth one interruption.
        let grants = Step(
            index: 0, kind: .resetPrivacyGrants, target: "com.t.app", targetFingerprint: nil,
            tier: .A, evidence: "clears grants", expectedBytes: 0, capability: .ok,
            reversible: false, costOfError: .medium,
            executionPhase: .privacyReset, disposition: .delete
        )
        let requirement = policy.requirement(for: plan([grants, step(1)]), lastAuthenticated: nil)
        XCTAssertTrue(requirement.needsPrompt)
        guard case .humanPresence(let reason) = requirement else { return XCTFail() }
        XCTAssertTrue(reason.contains("privacy permissions"), reason)
        XCTAssertTrue(reason.contains("TestApp"), "The prompt must name what is being removed")
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
