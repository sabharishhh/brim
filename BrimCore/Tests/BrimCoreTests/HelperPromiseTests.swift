@testable import BrimCore
import XCTest

/// A plan hands the helper only what the helper will take.
///
/// Anything that needed an administrator became a step for the helper,
/// wherever it was. The helper is confined to dead job files and dead
/// command links, so a preference file in a root-owned folder was
/// approved, handed over, refused or never attempted, and reported
/// afterwards as still there with no reason anyone could act on. The
/// review is where that has to be said, so the item stays out of the plan
/// and says why.
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
