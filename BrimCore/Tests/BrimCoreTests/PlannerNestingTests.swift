@testable import BrimCore
import Foundation
import XCTest

final class PlannerNestingTests: XCTestCase {
    /// A large review used to compare every item with every selected path.
    /// Retain independent siblings while emitting a containing removal once.
    func testLargeReviewKeepsSiblingsAndCollapsesSelectedDescendants() {
        let siblings = (0 ..< 2800).map { row("/tmp/review/cache-\($0)") }
        let items = siblings + [
            row("/tmp/review/host"), row("/tmp/review/host/contents/data"),
            row("/tmp/review/hostname/contents/data"),
            row("/tmp/review/kept", selection: .unselected),
            row("/tmp/review/kept/selected"), row("/tmp/review/host")
        ]
        let plan = plan(items)
        let paths = plan.steps.filter { $0.kind == .trashPath }.map(\.target)
        XCTAssertEqual(paths.count, 2803)
        XCTAssertEqual(Array(paths.prefix(2800)), siblings.map(\.footprintItem.evidence.url.path))
        XCTAssertTrue(paths.contains("/tmp/review/host"))
        XCTAssertFalse(paths.contains("/tmp/review/host/contents/data"))
        XCTAssertTrue(paths.contains("/tmp/review/hostname/contents/data"))
        XCTAssertTrue(paths.contains("/tmp/review/kept/selected"))
    }

    func testUnavailablePrivilegedParentDoesNotHideWritableDescendant() {
        let plan = plan([
            row("/tmp/review/protected", capability: .needsHelper),
            row("/tmp/review/protected/writable")
        ])
        XCTAssertEqual(plan.steps.filter { $0.kind == .trashPath }.map(\.target),
                       ["/tmp/review/protected/writable"])
        XCTAssertTrue(plan.excludedItems.contains { $0.target == "/tmp/review/protected" })
    }

    private func row(
        _ path: String, selection: SelectionState = .selected, capability: Capability = .ok
    ) -> EvaluatedItem {
        EvaluatedItem(footprintItem: FootprintItem(
            evidence: Evidence(url: URL(fileURLWithPath: path), tier: .A,
                               mechanism: "test", humanSentence: "Application data"),
            sizeBytes: 1, capability: capability
        ), selection: selection, costOfError: .low)
    }

    private func plan(_ items: [EvaluatedItem]) -> Plan {
        let identity = Identity(name: "Example")
        return Planner().createPlan(from: EvaluatedFootprint(identity: identity, items: items),
                                    intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
                                    engineVersion: "test")
    }
}
