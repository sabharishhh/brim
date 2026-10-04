import BrimCore
import BrimOps
import BrimProtocol
@testable import BrimService
import Foundation
import Testing

struct LaunchdUndoReceiptTests {
    @Test func anUnverifiedStopKeepsItsDeclarationAndCanRetryRecovery() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("brim-stop-receipt-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let declaration = base.appendingPathComponent("job.plist")
        try Data("reviewed declaration".utf8).write(to: declaration)
        let plan = try Self.plan(for: declaration, fingerprint: Self.fingerprint(of: declaration))
        let plans = base.appendingPathComponent("Plans")
        let journals = base.appendingPathComponent("Journal")
        let store = JournalStore(directoryURL: journals)
        let recovery = JobRecoveryRetry()
        let runtime = LaunchdRuntimeClient(restore: { _ in try await recovery.restore() },
                                           observe: { _, _ in .unknown("Fixture observation failed.") },
                                           stopWithReceipt: { _ in
                                               throw LaunchdStopError.verificationFailedAfterStop(
                                                   "Fixture postcheck failed."
                                               )
                                           })
        let journal = try await Executor(journalStore: store, launchdRuntime: runtime).execute(plan: plan)
        #expect(journal.stepOutcomes[0]?.hasPrefix("stopped_unverified:") == true)
        #expect(journal.stepOutcomes[1] != "ok")
        #expect(journal.stepTrashedURLs?[1] == nil)
        #expect(PathObservation.observe(declaration.path).isPresent)
        try await PlanStore(directoryURL: plans).save(plan: plan)
        let ledger = base.appendingPathComponent("Ledgers")
        try await LedgerStore(directoryURL: ledger).write(entry: LedgerEntry(
            planId: plan.planId, planHash: "fixture", executedAt: Date(), outcomes: [], recoveredBytes: 0
        ))
        let service = BrimService(root: FileSystemRoot(rootURL: base, userName: "fixture"),
                                  brimAppURL: base.appendingPathComponent("Brim.app"),
                                  planStoreDirectory: plans, journalStoreDirectory: journals, launchdRuntime: runtime)
        #expect(try await service.recoverableItems().map(\.planId) == [plan.planId])
        await #expect(throws: (any Error).self) {
            try await service.undo(planId: plan.planId)
        }
        let firstAttempt = try #require(await store.load(planId: plan.planId))
        #expect(firstAttempt.restoredAt == nil)
        #expect(firstAttempt.restoreOutcomes?[0] != "ok")
        #expect(try await service.recoverableItems().map(\.planId) == [plan.planId])
        try await service.undo(planId: plan.planId)
        let restored = try #require(await store.load(planId: plan.planId))
        #expect(restored.restoredAt != nil)
        #expect(restored.restoreOutcomes?[0] == "ok")
        #expect(restored.stepOutcomes == journal.stepOutcomes)
        #expect(await recovery.calls == 2)
        #expect(try await service.recoverableItems().isEmpty)
    }

    @Test func restoringAnAlreadyAbsentJobsFilesDoesNotStartTheJob() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("brim-undo-receipt-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let declaration = base.appendingPathComponent("job.plist")
        let recovery = base.appendingPathComponent("saved-job.plist")
        try Data("fixture".utf8).write(to: recovery)
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
                        intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(name: "Fixture")),
                        steps: [
                            Step(index: 0, kind: .unloadLaunchdJob, target: declaration.path, targetFingerprint: nil,
                                 tier: .A, evidence: "Fixture", expectedBytes: 0, capability: .ok,
                                 reversible: true, costOfError: .medium, executionPhase: .launchd),
                            Step(index: 1, kind: .removeLaunchdPlist, target: declaration.path, targetFingerprint: nil,
                                 tier: .A, evidence: "Fixture", expectedBytes: 0, capability: .ok,
                                 reversible: true, costOfError: .low, executionPhase: .launchd, disposition: .trash)
                        ], excludedItems: [], expectedTotalBytes: 0)
        let plans = base.appendingPathComponent("Plans")
        let journals = base.appendingPathComponent("Journal")
        try await PlanStore(directoryURL: plans).save(plan: plan)
        try await JournalStore(directoryURL: journals).write(entry: JournalEntry(
            planId: plan.planId, startedAt: Date(), status: .completed,
            stepOutcomes: [0: "already_gone", 1: "ok"], stepTrashedURLs: [1: recovery]
        ))
        let runtime = LaunchdRuntimeClient(stop: { _ in }, restore: { _ in
            Issue.record("Undo started a job that was absent before removal.")
        }, observe: { _, _ in .absent }, stopWithReceipt: { _ in false })
        let service = BrimService(root: FileSystemRoot(rootURL: base, userName: "fixture"),
                                  brimAppURL: base.appendingPathComponent("Brim.app"),
                                  planStoreDirectory: plans, journalStoreDirectory: journals, launchdRuntime: runtime)
        try await service.undo(planId: plan.planId)
        #expect(PathObservation.observe(declaration.path).isPresent)
    }

    private static func fingerprint(of declaration: URL) throws -> TargetFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: declaration.path)
        return try TargetFingerprint(
            dev: #require(attributes[.systemNumber] as? NSNumber).int32Value,
            ino: #require(attributes[.systemFileNumber] as? NSNumber).uint64Value,
            mtime: #require(attributes[.modificationDate] as? Date)
        )
    }

    private static func plan(for declaration: URL, fingerprint: TargetFingerprint?) -> Plan {
        Plan(planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
             intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(name: "Fixture")),
             steps: [
                 Step(index: 0, kind: .unloadLaunchdJob, target: declaration.path,
                      targetFingerprint: fingerprint, tier: .A, evidence: "Fixture", expectedBytes: 0,
                      capability: .ok, reversible: true, costOfError: .medium, executionPhase: .launchd),
                 Step(index: 1, kind: .removeLaunchdPlist, target: declaration.path,
                      targetFingerprint: fingerprint, tier: .A, evidence: "Fixture", expectedBytes: 0,
                      capability: .ok, reversible: true, costOfError: .low, executionPhase: .launchd,
                      disposition: .trash)
             ], excludedItems: [], expectedTotalBytes: 0)
    }
}

private actor JobRecoveryRetry {
    private(set) var calls = 0

    func restore() throws {
        calls += 1
        if calls == 1 {
            throw NSError(domain: "Fixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Recovery could not be checked."
            ])
        }
    }
}
