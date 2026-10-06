import BrimCore
import BrimProtocol
@testable import BrimUI
import XCTest

/// eqMac's removal took the app, its audio driver, settings and caches, and
/// its device left the Sound menu at once. The result still read as a
/// partial removal: a caution mark over "could not check" rows for
/// configuration profiles, VPN settings and privacy grants, none of which
/// the app had.
final class RemovalSummaryTests: XCTestCase {
    private let app = "/Applications/X.app"

    private func step(
        _ index: Int, _ target: String, bytes: Int64 = 10, kind: StepKind = .trashPath,
        phase: ExecutionPhase = .auxiliary
    ) -> Step {
        Step(index: index, kind: kind, target: target, targetFingerprint: nil, tier: .B, evidence: "test",
             expectedBytes: bytes, capability: .ok, reversible: true, costOfError: .low, executionPhase: phase,
             disposition: .trash)
    }

    private var plan: Plan {
        Plan(planId: UUID(), createdAt: Date(), engineVersion: "t", osVersion: "t",
             intent: PlanIntent(type: .uninstall,
                                subjectIdentity: Identity(bundleID: "com.x.app", name: "X", bundlePath: app)),
             steps: [
                 step(0, app, bytes: 50_000_000, phase: .appBundle),
                 step(1, "/Users/me/Library/Caches/com.x.app", bytes: 2_000_000),
                 step(2, "/Users/me/Library/Preferences/com.x.app.plist", bytes: 4000),
                 step(3, app, bytes: 0, kind: .unregisterLaunchServices, phase: .registration)
             ],
             excludedItems: [], expectedTotalBytes: 0)
    }

    private func report(
        declaredNone: [DeclaredCapability], observations: [RegistrationVerification], unticked: [String] = []
    ) -> RemovalReport {
        RemovalReport(checkedGone: 3, registrationsChecked: [], declaredNone: declaredNone, keptByMacOS: [],
                      stillThere: 0, leftUnticked: unticked, unknownPaths: [],
                      registrationObservations: observations)
    }

    private let profiles = RegistrationVerification(
        capability: .configurationProfile, observedAt: Date(),
        coverage: .unavailable(.configurationProfile, "Only returned profile references were inspected."),
        remaining: []
    )

    func testAnUncheckableKindTheAppNeverHadIsNotNews() {
        let report = report(declaredNone: [.configurationProfile], observations: [profiles])
        XCTAssertTrue(report.unansweredChecks.isEmpty)
        let summary = RemovalSummary(result: VerificationResult(planId: plan.planId, expectedBytes: 0,
                                                                recoveredBytes: 0, success: true, report: report),
                                     plan: plan)
        XCTAssertTrue(summary.isDone)
        XCTAssertEqual(summary.headline, "X is gone")
        XCTAssertEqual(summary.subline, "52 MB in the Trash")
        XCTAssertEqual(summary.went.map(\.loss), [.app, .settings, .rebuilds])
        XCTAssertEqual(summary.records, 1)
        XCTAssertTrue(summary.stayed.isEmpty)
    }

    /// A kind the review had reason to expect is still worth saying, once
    /// and quietly, without taking the removal away from the person.
    func testAnUncheckableKindTheAppDeclaresStaysAQuietLine() {
        let report = report(declaredNone: [], observations: [profiles], unticked: ["/Users/me/Library/Logs/X"])
        let summary = RemovalSummary(result: VerificationResult(planId: plan.planId, expectedBytes: 0,
                                                                recoveredBytes: 0, success: false, report: report),
                                     plan: plan)
        XCTAssertTrue(summary.isDone)
        XCTAssertEqual(summary.stayed.map(\.label), ["Left unticked", DeclaredCapability.configurationProfile.title])
        XCTAssertEqual(summary.revealable, ["/Users/me/Library/Logs/X"])
    }

    func testAnAppThatDidNotMoveIsNotGone() {
        let result = VerificationResult(planId: plan.planId, expectedBytes: 0, recoveredBytes: 0, success: false,
                                        reason: "The app is open.", remainingPaths: [app],
                                        report: report(declaredNone: [], observations: []))
        let summary = RemovalSummary(result: result, plan: plan)
        XCTAssertFalse(summary.isDone)
        XCTAssertEqual(summary.headline, "X is still here")
        XCTAssertEqual(summary.stayed.map(\.detail), ["Could not be moved"])
    }
}
