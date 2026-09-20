import XCTest
@testable import BrimCore

/// The order steps run in, and the order they are undone in, is the rule that
/// keeps an interrupted or reversed uninstall from corrupting a footprint:
/// an archive copy must exist before anything is destroyed, a launchd job must
/// be unloaded before its plist is removed, and the app bundle must be trashed
/// last (and restored first, since auxiliary files can live beneath it).
final class PlanStepOrderingTests: XCTestCase {

    private func step(_ index: Int, _ phase: ExecutionPhase, target: String = "/tmp/x", kind: StepKind = .trashPath) -> Step {
        Step(
            index: index,
            kind: kind,
            target: target,
            targetFingerprint: nil,
            tier: .A,
            evidence: "test",
            expectedBytes: 0,
            capability: .ok,
            reversible: true,
            costOfError: .low,
            executionPhase: phase
        )
    }

    private func plan(_ steps: [Step]) -> Plan {
        Plan(
            planId: UUID(),
            createdAt: Date(),
            engineVersion: "test",
            osVersion: "test",
            intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: "com.test.app", name: "TestApp")),
            steps: steps,
            excludedItems: [],
            expectedTotalBytes: 0
        )
    }

    func testExecutionOrderRunsArchiveFirstAndAppBundleLast() {
        // Deliberately shuffled relative to the order they must run in.
        let subject = plan([
            step(0, .appBundle, target: "/Applications/TestApp.app"),
            step(1, .auxiliary, target: "/Users/x/Library/Caches/TestApp"),
            step(2, .launchd, target: "/Users/x/Library/LaunchAgents/com.test.plist"),
            step(3, .archive, target: "/Users/x/Archive/TestApp.zip")
        ])

        XCTAssertEqual(
            subject.executionOrderedSteps.map(\.executionPhase),
            [.archive, .auxiliary, .launchd, .appBundle]
        )
    }

    func testUndoOrderIsTheExactReverseOfExecutionOrder() {
        let subject = plan([
            step(0, .appBundle),
            step(1, .auxiliary),
            step(2, .launchd),
            step(3, .archive)
        ])

        XCTAssertEqual(
            subject.undoOrderedSteps.map(\.index),
            subject.executionOrderedSteps.map(\.index).reversed()
        )
    }

    func testTiesWithinAPhaseRunInPlannerOrderAndUndoInReverse() {
        let subject = plan([
            step(2, .auxiliary, target: "/c"),
            step(0, .auxiliary, target: "/a"),
            step(1, .auxiliary, target: "/b")
        ])

        XCTAssertEqual(subject.executionOrderedSteps.map(\.index), [0, 1, 2])
        XCTAssertEqual(subject.undoOrderedSteps.map(\.index), [2, 1, 0])
    }

    func testUndoRestoresTheAppBundleBeforeFilesBeneathIt() {
        // An auxiliary file inside the bundle cannot be put back until the
        // bundle directory itself is back.
        let subject = plan([
            step(0, .appBundle, target: "/Applications/TestApp.app"),
            step(1, .auxiliary, target: "/Applications/TestApp.app/Contents/Helper")
        ])

        XCTAssertEqual(
            subject.undoOrderedSteps.map(\.target),
            ["/Applications/TestApp.app", "/Applications/TestApp.app/Contents/Helper"]
        )
    }

    func testUnloadPrecedesPlistRemovalOnApplyAndReversesOnUndo() {
        // Both are .launchd, so the planner's index ordering is what keeps the
        // unload ahead of the removal — and the restore ahead of the reload.
        let unload = step(0, .launchd, target: "/Users/x/Library/LaunchAgents/com.test.plist", kind: .unloadLaunchdJob)
        let remove = step(1, .launchd, target: "/Users/x/Library/LaunchAgents/com.test.plist", kind: .removeLaunchdPlist)
        let subject = plan([remove, unload])

        XCTAssertEqual(subject.executionOrderedSteps.map(\.kind), [.unloadLaunchdJob, .removeLaunchdPlist])
        XCTAssertEqual(subject.undoOrderedSteps.map(\.kind), [.removeLaunchdPlist, .unloadLaunchdJob])
    }

    func testOrderingIsStableForAnEmptyOrSingleStepPlan() {
        XCTAssertTrue(plan([]).executionOrderedSteps.isEmpty)
        XCTAssertTrue(plan([]).undoOrderedSteps.isEmpty)

        let single = plan([step(0, .appBundle)])
        XCTAssertEqual(single.executionOrderedSteps.map(\.index), [0])
        XCTAssertEqual(single.undoOrderedSteps.map(\.index), [0])
    }
}
