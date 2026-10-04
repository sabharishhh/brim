import BrimCore
import BrimProtocol
@testable import BrimService
import Foundation
import Testing

struct PendingRemovalRecheckTests {
    /// A finished execution can still leave macOS registrations behind.
    @Test func unfinishedObservationsRemainQueued() {
        let unchecked = entry()
        #expect(PendingRemovalRecheck.needsCheck(unchecked))
        var unresolved = unchecked
        unresolved.verifications = [verification(unresolved.planId, success: false)]
        #expect(PendingRemovalRecheck.needsCheck(unresolved))
        unresolved.verifications = [verification(unresolved.planId, success: true,
                                                 remaining: ["/Applications/Example.app"])]
        #expect(PendingRemovalRecheck.needsCheck(unresolved))
    }

    @Test func latestSuccessfulObservationStopsRechecks() {
        var completed = entry()
        completed.verifications = [verification(completed.planId, success: false),
                                   verification(completed.planId, success: true)]
        #expect(PendingRemovalRecheck.needsCheck(completed) == false)
        var neverExecuted = entry()
        neverExecuted.stepOutcomes = [:]
        #expect(PendingRemovalRecheck.needsCheck(neverExecuted) == false)
    }

    /// Restoration must not be treated as an uninstall that failed to stay gone.
    @Test func completedAndPartialRestorationsAreNotQueued() {
        var restored = entry()
        restored.restoredAt = Date(timeIntervalSince1970: 10)
        #expect(PendingRemovalRecheck.needsCheck(restored) == false)
        var partialRestore = entry()
        partialRestore.restoreOutcomes = [0: "restore_failed"]
        #expect(PendingRemovalRecheck.needsCheck(partialRestore) == false)
    }

    @Test func startupOnlyRechecksWholeApplicationRemovals() {
        let identity = Identity(bundleID: "com.example.app", name: "Example")
        let target = URL(fileURLWithPath: "/Applications/Example.app")
        #expect(PendingRemovalRecheck.isRemoval(plan(PlanIntent(type: .uninstall, subjectIdentity: identity))))
        #expect(PendingRemovalRecheck.isRemoval(plan(PlanIntent(type: .uninstall, subjectIdentity: identity,
                                                                specificTarget: target))) == false)
        #expect(PendingRemovalRecheck.isRemoval(plan(PlanIntent(type: .uninstall, subjectIdentity: identity,
                                                                specificTargets: [target]))) == false)
        #expect(PendingRemovalRecheck.isRemoval(plan(PlanIntent(type: .toolCleanup,
                                                                subjectIdentity: identity))) == false)
    }

    @Test func oldestObservationRunsFirstWithStableTies() throws {
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let neverChecked = entry(started: 1)
        var first = entry(id: firstID, started: 50)
        first.verifications = [verification(firstID, success: false, observed: 10)]
        var second = entry(id: secondID, started: 2)
        second.verifications = [verification(secondID, success: false, observed: 10)]
        var recentlyChecked = entry(started: 0)
        recentlyChecked.verifications = [verification(recentlyChecked.planId, success: false, observed: 20)]
        var settled = entry(started: 0)
        settled.verifications = [verification(settled.planId, success: true)]
        let ordered = PendingRemovalRecheck.ordered([recentlyChecked, second, settled, first, neverChecked])
        #expect(ordered.map(\.planId) == [neverChecked.planId, firstID, secondID, recentlyChecked.planId])
    }

    private func entry(id: UUID = UUID(), started: TimeInterval = 1) -> JournalEntry {
        JournalEntry(planId: id, startedAt: Date(timeIntervalSince1970: started), status: .completed,
                     stepOutcomes: [0: "ok"])
    }

    private func verification(
        _ id: UUID, success: Bool, remaining: Set<String> = [], observed: TimeInterval? = nil
    ) -> VerificationResult {
        VerificationResult(planId: id, expectedBytes: 0, recoveredBytes: 0, success: success,
                           remainingPaths: remaining, observedAt: observed.map { Date(timeIntervalSince1970: $0) })
    }

    private func plan(_ intent: PlanIntent) -> Plan {
        let step = Step(index: 0, kind: .trashPath, target: "/Applications/Example.app", targetFingerprint: nil,
                        tier: .A, evidence: "Fixture", expectedBytes: 0, capability: .ok,
                        reversible: true, costOfError: .medium, executionPhase: .appBundle)
        return Plan(planId: UUID(), createdAt: Date(timeIntervalSince1970: 1), engineVersion: "test",
                    osVersion: "test", intent: intent, steps: [step], excludedItems: [], expectedTotalBytes: 0)
    }
}
