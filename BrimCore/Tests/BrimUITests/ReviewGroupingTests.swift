import BrimCore
@testable import BrimUI
import XCTest

/// The review uses the inspector's groups, so a file can be followed from
/// why it is the app's to what happened to it.
final class ReviewGroupingTests: XCTestCase {
    private func step(_ index: Int, _ target: String, kind: StepKind = .trashPath) -> Step {
        Step(index: index, kind: kind, target: target, targetFingerprint: nil, tier: .B,
             evidence: "test", expectedBytes: 10, capability: .ok, reversible: true, costOfError: .low)
    }

    private func plan(steps: [Step], excluded: [ExcludedItem]) -> Plan {
        Plan(planId: UUID(), createdAt: Date(), engineVersion: "t", osVersion: "t",
             intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: "com.x.app", name: "X")),
             steps: steps, excludedItems: excluded, expectedTotalBytes: 0)
    }

    func testEachGroupHoldsWhatMovesWhatIsOfferedAndWhatStaysInDisplayOrder() {
        let groups = UninstallExecutionModel.grouped(plan(
            steps: [
                step(0, "/Users/me/Library/Caches/com.x.app"),
                step(1, "/Applications/X.app"),
                step(2, "com.x.app.pkg", kind: .forgetReceipt),
                step(3, "/Applications/X.app", kind: .resetPrivacyGrants),
                step(4, "/Users/me/Library/Preferences/com.x.app.plist")
            ],
            excluded: [
                ExcludedItem(target: "/Users/me/Library/Application Support/X", reason: "", canBeTickedByHand: true),
                ExcludedItem(
                    target: "/Users/me/Library/Group Containers/shared", reason: "Shared", canBeTickedByHand: false
                ),
                ExcludedItem(target: "/Users/me/Library/Containers/io.x.app", reason: "Old plan")
            ]
        ))
        XCTAssertEqual(groups.map(\.loss), [.app, .settings, .data, .rebuilds, .records])
        let data = groups.first { $0.loss == .data }
        XCTAssertEqual(data?.offers.map(\.target), ["/Users/me/Library/Application Support/X"])
        // A row with no tick state comes from an older plan and is not tickable.
        XCTAssertEqual(data?.staying.map(\.target).sorted(),
                       ["/Users/me/Library/Containers/io.x.app", "/Users/me/Library/Group Containers/shared"])
        // The privacy reset is bookkeeping and is never shown as a file.
        XCTAssertEqual(groups.first { $0.loss == .app }?.steps.map(\.kind), [.trashPath])
        XCTAssertEqual(groups.first { $0.loss == .records }?.steps.map(\.target), ["com.x.app.pkg"])
    }
}
