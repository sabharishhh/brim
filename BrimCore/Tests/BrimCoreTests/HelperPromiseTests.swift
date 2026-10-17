@testable import BrimCore
import XCTest

/// A plan hands administrator cleanup only what it will take. Anything else
/// that needs an administrator stays out of the plan and says why in the
/// review, rather than failing after approval.
final class HelperPromiseTests: XCTestCase {
    private let identity = Identity(bundleID: nil, name: "Leftovers")

    private func needingAdministrator(_ path: String) -> EvaluatedItem {
        EvaluatedItem(
            footprintItem: FootprintItem(
                evidence: Evidence(
                    url: URL(fileURLWithPath: path), tier: .A, mechanism: "DirectTarget",
                    humanSentence: "Named for removal"
                ),
                sizeBytes: 181, capability: .needsHelper
            ),
            selection: .selected, costOfError: .low
        )
    }

    private func plan(_ paths: [String]) -> Plan {
        Planner().createPlan(
            from: EvaluatedFootprint(identity: identity, items: paths.map(needingAdministrator)),
            intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
            engineVersion: "test"
        )
    }

    func testSomethingTheHelperWillNotTakeIsKeptOutWithItsReason() {
        let path = "/Library/Preferences/com.vendor.gone.plist"
        let result = plan([path])

        XCTAssertFalse(result.steps.contains { $0.target == path }, "Promised, then refused")
        let kept = result.excludedItems.first { $0.target == path }
        XCTAssertNotNil(kept)
        XCTAssertEqual(kept?.canBeTickedByHand, false)
        XCTAssertTrue(kept?.reason.contains("/Library/Preferences") ?? false)
        XCTAssertEqual(result.expectedTotalBytes, 0)
    }

    func testAJobFileTheHelperWouldConsiderIsStillItsToTake() {
        let path = "/Library/LaunchAgents/com.vendor.updater.plist"
        let result = plan([path])

        XCTAssertEqual(result.steps.first { $0.target == path }?.kind, .trashPathPrivileged)
    }
}
