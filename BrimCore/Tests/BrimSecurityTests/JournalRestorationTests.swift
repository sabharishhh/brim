import BrimProtocol
@testable import BrimService
import Foundation
import Testing

struct JournalRestorationTests {
    @Test func legacyJournalsDoNotGainRestorationReceipts() throws {
        let original = JournalEntry(
            planId: UUID(), startedAt: Date(timeIntervalSince1970: 1), status: .completed,
            stepOutcomes: [0: "ok"], restoredAt: Date(timeIntervalSince1970: 2), restoreOutcomes: [0: "ok"]
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "restoredAt")
        object.removeValue(forKey: "restoreOutcomes")
        let legacy = try JSONDecoder().decode(JournalEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.restoredAt == nil)
        #expect(legacy.restoreOutcomes == nil)
        #expect(legacy.stepOutcomes == original.stepOutcomes)
    }

    @Test func restorationRetriesKeepExecutionReceiptsAndPriorRechecks() async throws {
        let fixture = try RestorationJournalFixture()
        let original = fixture.entry()
        let firstCheck = fixture.verification(reason: "Before restoration")
        let secondCheck = fixture.verification(reason: "While restoring")
        try await fixture.store.write(entry: original)
        try await fixture.store.recordVerification(firstCheck)
        try await fixture.store.recordRestoreOutcome(planId: fixture.planID, stepIndex: 0, outcome: "restore_failed")
        let failed = try #require(await fixture.store.load(planId: fixture.planID))
        #expect(failed.restoredAt == nil)
        #expect(failed.restoreOutcomes == [0: "restore_failed"])
        try await fixture.store.recordVerification(secondCheck)
        try await fixture.store.recordRestoreOutcome(planId: fixture.planID, stepIndex: 0, outcome: "ok")
        try await fixture.store.recordRestoreOutcome(planId: fixture.planID, stepIndex: 1, outcome: "ok")
        let completedAt = Date(timeIntervalSince1970: 3)
        try await fixture.store.markRestored(planId: fixture.planID, at: completedAt)
        try await fixture.store.markRestored(planId: fixture.planID, at: Date(timeIntervalSince1970: 4))
        let reopened = JournalStore(directoryURL: fixture.directory)
        let restored = try #require(await reopened.load(planId: fixture.planID))
        #expect(restored.restoredAt == completedAt)
        #expect(restored.restoreOutcomes == [0: "ok", 1: "ok"])
        #expect(restored.stepOutcomes == original.stepOutcomes)
        #expect(restored.stepTrashedURLs == original.stepTrashedURLs)
        #expect(restored.status == original.status)
        #expect(restored.startedAt == original.startedAt)
        #expect(restored.freeSpaceBefore == original.freeSpaceBefore)
        #expect(restored.freeSpaceAfter == original.freeSpaceAfter)
        #expect(restored.verifications == [firstCheck, secondCheck])
    }

    @Test func concurrentMetadataUpdatesPreserveEachIndependentReceipt() async throws {
        let fixture = try RestorationJournalFixture()
        try await fixture.store.write(entry: fixture.entry())
        let check = fixture.verification(reason: "Rechecked")
        async let restore: Void = fixture.store.recordRestoreOutcome(
            planId: fixture.planID,
            stepIndex: 0,
            outcome: "ok"
        )
        async let observation: Void = fixture.store.recordVerification(check)
        async let completion: Void = fixture.store.markRestored(
            planId: fixture.planID,
            at: Date(timeIntervalSince1970: 3)
        )
        _ = try await (restore, observation, completion)
        let latest = try #require(await fixture.store.load(planId: fixture.planID))
        #expect(latest.restoreOutcomes == [0: "ok"])
        #expect(latest.verifications == [check])
        #expect(latest.restoredAt == Date(timeIntervalSince1970: 3))
        #expect(latest.stepOutcomes == fixture.entry().stepOutcomes)
    }

    @Test func aMissingJournalCannotProduceRestorationEvidence() async throws {
        let fixture = try RestorationJournalFixture()
        await #expect(throws: NSError.self) {
            try await fixture.store.recordRestoreOutcome(planId: fixture.planID, stepIndex: 0, outcome: "ok")
        }
        await #expect(throws: NSError.self) {
            try await fixture.store.markRestored(planId: fixture.planID, at: Date())
        }
        #expect(try await fixture.store.load(planId: fixture.planID) == nil)
    }
}

private final class RestorationJournalFixture: Sendable {
    let directory: URL
    let store: JournalStore
    let planID = UUID()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("restoration-journal-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = JournalStore(directoryURL: directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func entry() -> JournalEntry {
        JournalEntry(planId: planID, startedAt: Date(timeIntervalSince1970: 1), status: .completed,
                     stepOutcomes: [0: "ok", 1: "privacy_grants_not_cleared"],
                     stepTrashedURLs: [0: directory.appendingPathComponent("recovery")],
                     freeSpaceBefore: 10, freeSpaceAfter: 20)
    }

    func verification(reason: String) -> VerificationResult {
        VerificationResult(planId: planID, expectedBytes: 10, recoveredBytes: 10, success: false, reason: reason)
    }
}
