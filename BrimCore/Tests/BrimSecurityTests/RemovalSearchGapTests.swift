import BrimCore
import BrimProtocol
import Foundation
import Testing

/// Manually removing all found items does not complete an unfinished search.
struct RemovalSearchGapTests {
    @Test func verificationPreservesSearchGapsAfterAllSelectedItemsAreGone() throws {
        let gap = ScanCompleteness(unreadable: ["/fixture/Library/Logs"], timedOut: ["/fixture/SDK"])
        let step = Step(index: 0, kind: .trashPath, target: "/fixture/Editor.app", targetFingerprint: nil,
                        tier: .A, evidence: "Selected bundle", expectedBytes: 1, capability: .ok,
                        reversible: true, costOfError: .medium)
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
                        intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(name: "Editor")),
                        steps: [step], excludedItems: [], expectedTotalBytes: 1, scanCompleteness: gap)
        let report = RemovalReport.build(plan: plan, remaining: [], recorded: [:], staleRegistrations: 0,
                                         privacyResetFailed: false, survivingExtensions: [])
        #expect(report.checkedGone == 1)
        #expect(report.leftUnticked.isEmpty)
        #expect(report.scanCompleteness == gap)
        let saved = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(RemovalReport.self, from: saved).scanCompleteness == gap)
    }

    @Test func olderReportsDecodeAndCompleteReportsKeepTheirWireShape() throws {
        let old = Data(#"{"checkedGone":1,"registrationsChecked":[],"declaredNone":[],"keptByMacOS":[],"stillThere":0}"#
            .utf8)
        let decoded = try JSONDecoder().decode(RemovalReport.self, from: old)
        #expect(decoded.scanCompleteness == nil)
        let complete = RemovalReport(checkedGone: 1, registrationsChecked: [], declaredNone: [], keptByMacOS: [],
                                     stillThere: 0, scanCompleteness: .complete)
        let encoded = try JSONEncoder().encode(complete)
        #expect(String(data: encoded, encoding: .utf8)?.contains("scanCompleteness") == false)
    }
}
