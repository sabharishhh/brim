import BrimCore
import BrimOps
import BrimProtocol
@testable import BrimService
import Foundation
import Testing

private actor RecheckGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if !entered {
            await withCheckedContinuation { entryWaiter = $0 }
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

struct RegistrationLifecycleTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("brim-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func service(_ base: URL, runtime: LaunchdRuntimeClient) -> BrimService {
        BrimService(root: FileSystemRoot(rootURL: base, userName: "fixture"),
                    brimAppURL: base.appendingPathComponent("Brim.app"),
                    planStoreDirectory: base.appendingPathComponent("Plans"),
                    journalStoreDirectory: base.appendingPathComponent("Journal"), launchdRuntime: runtime)
    }

    @Test func loadedSharedJobIsNotCountedAsAnOwnedRemainingJob() async throws {
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let record = Registration(kind: .launchdJob, identifier: "org.example.shared", label: "Shared worker",
                                  targetExists: false, recordPath: base.appendingPathComponent("job.plist").path,
                                  evidence: "Shared job declaration.", namespace: "gui/501")
        let instance = service(base, runtime: .init(observeReviewed: { _ in .present }))
        let original = RegistrationVerification(capability: .launchdJob, observedAt: Date(),
                                                coverage: .available(.launchdJob), remaining: [], preserved: [record])
        let result = await instance.recheckReviewedJobs(original, reviewed: [record], observedAt: Date())
        #expect(result.remaining.isEmpty)
        #expect(result.preserved == [record])
    }

    @Test func aReusedLabelDoesNotAttributeAnotherLoadedJobToTheRemovedApp() async throws {
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let record = Registration(kind: .launchdJob, identifier: "org.example.worker", label: "Worker",
                                  targetExists: false, recordPath: base.appendingPathComponent("job.plist").path,
                                  evidence: "Reviewed declaration.", namespace: "gui/501")
        let instance = service(base, runtime: .init(observe: { _, _ in .present }, observeReviewed: { _ in .absent }))
        let result = await instance.recheckReviewedJobs(
            RegistrationVerification(capability: .launchdJob, observedAt: Date(),
                                     coverage: .available(.launchdJob), remaining: []),
            reviewed: [record], observedAt: Date()
        )
        #expect(result.remaining.isEmpty)
    }

    @Test(arguments: [false, true])
    func missingExecutionReceiptsCannotBecomeSuccessfulRemoval(corrupt: Bool) async throws {
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
                        intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(name: "Fixture"),
                                           specificTarget: base.appendingPathComponent("missing")),
                        steps: [Step(index: 0, kind: .trashPath, target: base.appendingPathComponent("missing").path,
                                     targetFingerprint: nil, tier: .A, evidence: "Fixture", expectedBytes: 0,
                                     capability: .ok, reversible: true, costOfError: .low)],
                        excludedItems: [], expectedTotalBytes: 0)
        try await PlanStore(directoryURL: base.appendingPathComponent("Plans")).save(plan: plan)
        if corrupt {
            let journalFolder = base.appendingPathComponent("Journal")
            try FileManager.default.createDirectory(at: journalFolder, withIntermediateDirectories: true)
            let receipt = journalFolder.appendingPathComponent("\(plan.planId.uuidString).journal")
            try Data("unreadable receipt".utf8).write(to: receipt)
        }
        let result = try await service(base, runtime: .init(observe: { _, _ in .absent })).verify(planId: plan.planId)
        #expect(!result.success)
        #expect(result.reason?.contains("record of this removal could not be read") == true)
        #expect(result.observedAt != nil)
    }

    @Test func recoveryCannotRaceWithAnInProgressRecheck() async throws {
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let record = Registration(kind: .launchdJob, identifier: "org.example.worker", label: "Worker",
                                  targetExists: false, recordPath: base.appendingPathComponent("job.plist").path,
                                  evidence: "Reviewed declaration.", namespace: "gui/501")
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
                        intent: PlanIntent(type: .uninstall,
                                           subjectIdentity: Identity(bundleID: "org.example.host", name: "Host")),
                        steps: [], excludedItems: [], expectedTotalBytes: 0).attaching(
            CapabilitySearchReport(checks: [.init(capability: .launchdJob, declaration: .declared,
                                                  coverage: .available(.launchdJob), registrations: [record])],
                                   signatureCoverage: [])
        )
        try await PlanStore(directoryURL: base.appendingPathComponent("Plans")).save(plan: plan)
        try await JournalStore(directoryURL: base.appendingPathComponent("Journal")).write(entry: .init(
            planId: plan.planId, startedAt: Date(), status: .completed
        ))
        let gate = RecheckGate()
        let instance = service(base, runtime: .init(observeReviewed: { _ in await gate.hold(); return .absent }))
        let checking = Task { try await instance.verify(planId: plan.planId) }
        await gate.waitUntilEntered()
        do {
            try await instance.undo(planId: plan.planId)
            Issue.record("Recovery entered while verification was awaiting a registration read.")
        } catch {
            #expect((error as NSError).code == 409)
        }
        await gate.release()
        _ = try await checking.value
    }
}
