import BrimCore
import BrimOps
@testable import BrimService
import Foundation
import Testing

struct RegistrationRecoverabilityTests {
    @Test func missingFilesDoNotTurnRegistrationReceiptsIntoRecoverableRemovals() async throws {
        let fixture = try RegistrationRecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        for kind in [StepKind.unregisterLaunchServices, .unloadLaunchdJob] {
            let name = kind == .unloadLaunchdJob ? "Missing.plist" : "Missing.app"
            let target = fixture.folder.appendingPathComponent(name)
            let plan = fixture.plan(target: target, registration: kind)
            try await fixture.record(plan, outcomes: [0: "already_gone", 1: "ok"])
        }
        // Home reported two removals and Empty in the Trash from successful
        // registration receipts, although neither had a file to put back.
        #expect(try await fixture.service.recoverableItems().isEmpty)
    }

    @Test func aStoppedJobNeedsItsDeclarationToRemainRecoverable() async throws {
        let fixture = try RegistrationRecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let declaration = fixture.folder.appendingPathComponent("Worker.plist")
        try Data("fixture declaration".utf8).write(to: declaration)
        let plan = try fixture.plan(target: declaration, registration: .unloadLaunchdJob,
                                    fingerprint: fixture.fingerprint(declaration))
        try await fixture.record(plan, outcomes: [0: "not_removed", 1: "stopped_unverified: Fixture gap."])
        #expect(try await fixture.service.recoverableItems().map(\.planId) == [plan.planId])
        try FileManager.default.removeItem(at: declaration)
        #expect(try await fixture.service.recoverableItems().isEmpty)
    }

    @Test func aReplacedOrModifiedJobDeclarationCannotBeRecoveredOrStarted() async throws {
        for replaced in [true, false] {
            let fixture = try RegistrationRecoveryFixture(runtime: LaunchdRuntimeClient(restore: { _ in
                Issue.record("Recovery started a declaration that no longer matches the stopped job.")
            }))
            defer { try? FileManager.default.removeItem(at: fixture.folder) }
            let declaration = fixture.folder.appendingPathComponent("Worker.plist")
            try Data("reviewed declaration".utf8).write(to: declaration)
            let fingerprint = try fixture.fingerprint(declaration)
            let plan = fixture.plan(target: declaration, registration: .unloadLaunchdJob,
                                    fingerprint: fingerprint)
            try await fixture.record(plan, outcomes: [0: "not_removed", 1: "stopped_unverified: Fixture gap."])
            #expect(try await fixture.service.recoverableItems().map(\.planId) == [plan.planId])

            // A successful stop retained the plist, and a later installer
            // reused that path. Path existence alone offered to start its job.
            if replaced {
                try FileManager.default.moveItem(at: declaration,
                                                 to: fixture.folder.appendingPathComponent("Retired.plist"))
            }
            try Data("another job's declaration".utf8).write(to: declaration)
            let modified = replaced ? fingerprint.mtime : fingerprint.mtime.addingTimeInterval(60)
            try FileManager.default.setAttributes([.modificationDate: modified],
                                                  ofItemAtPath: declaration.path)
            #expect(try (fixture.fingerprint(declaration).ino == fingerprint.ino) != replaced)
            #expect(try await fixture.service.recoverableItems().isEmpty)
            await #expect(throws: (any Error).self) {
                try await fixture.service.undo(planId: plan.planId)
            }
            let store = JournalStore(directoryURL: fixture.folder.appendingPathComponent("Journal"))
            let journal = try #require(await store.load(planId: plan.planId))
            #expect(journal.restoredAt == nil)
            #expect(journal.restoreOutcomes?[1] != "ok")
            #expect(try Data(contentsOf: declaration) == Data("another job's declaration".utf8))
        }
    }

    @Test func registrationRecoveryRetainsAnOwnedRestoredBundleButRejectsAReplacement() async throws {
        let fixture = try RegistrationRecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let bundle = fixture.folder.appendingPathComponent("Editor.app")
        try fixture.makeBundle(bundle, identifier: "org.example.editor")
        let fingerprint = try fixture.fingerprint(bundle)
        let plan = fixture.plan(target: bundle, registration: .unregisterLaunchServices, fingerprint: fingerprint)
        let oldTrashPath = fixture.folder.appendingPathComponent("Saved.app")
        try await fixture.record(plan, outcomes: [0: "ok", 1: "ok"],
                                 saved: [0: oldTrashPath], restored: [0: "ok"])
        #expect(try await fixture.service.recoverableItems().map(\.planId) == [plan.planId])
        try FileManager.default.removeItem(at: bundle)
        #expect(try await fixture.service.recoverableItems().isEmpty)
        try fixture.makeBundle(bundle, identifier: "org.other.replacement")
        #expect(try await fixture.service.recoverableItems().isEmpty)
    }

    @Test func anExistingBundleWithoutTheRecordedRestoreBindingIsNotRegistrationRecovery() async throws {
        let fixture = try RegistrationRecoveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let bundle = fixture.folder.appendingPathComponent("Editor.app")
        try fixture.makeBundle(bundle, identifier: "org.example.editor")
        let plan = try fixture.plan(target: bundle, registration: .unregisterLaunchServices,
                                    fingerprint: fixture.fingerprint(bundle))
        try await fixture.record(plan, outcomes: [0: "already_gone", 1: "ok"])
        #expect(try await fixture.service.recoverableItems().isEmpty)
    }
}

private struct RegistrationRecoveryFixture {
    let folder: URL
    let service: BrimService

    init(runtime: LaunchdRuntimeClient = .init()) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder.resolvingSymlinksInPath()
        service = BrimService(root: FileSystemRoot(rootURL: self.folder, userName: "fixture"),
                              brimAppURL: self.folder.appendingPathComponent("Brim.app"),
                              planStoreDirectory: self.folder.appendingPathComponent("Plans"),
                              journalStoreDirectory: self.folder.appendingPathComponent("Journal"),
                              launchdRuntime: runtime)
    }

    func plan(target: URL, registration: StepKind, fingerprint: TargetFingerprint? = nil) -> Plan {
        Plan(planId: UUID(), createdAt: Date(), engineVersion: "fixture", osVersion: "fixture",
             intent: PlanIntent(type: .uninstall,
                                subjectIdentity: Identity(bundleID: "org.example.editor", name: "Fixture")),
             steps: [
                 Step(index: 0, kind: registration == .unloadLaunchdJob ? .removeLaunchdPlist : .trashPath,
                      target: target.path, targetFingerprint: fingerprint, tier: .A, evidence: "Fixture",
                      expectedBytes: 10, capability: .ok, reversible: true, costOfError: .medium,
                      executionPhase: .appBundle, disposition: .trash),
                 Step(index: 1, kind: registration, target: target.path, targetFingerprint: fingerprint,
                      tier: .A, evidence: "Fixture", expectedBytes: 0, capability: .ok, reversible: true,
                      costOfError: .medium, executionPhase: .registration,
                      registrationBundleID: registration == .unregisterLaunchServices ? "org.example.editor" : nil)
             ], excludedItems: [], expectedTotalBytes: 10)
    }

    func record(
        _ plan: Plan, outcomes: [Int: String],
        saved: [Int: URL]? = nil, restored: [Int: String]? = nil
    ) async throws {
        try await PlanStore(directoryURL: folder.appendingPathComponent("Plans")).save(plan: plan)
        try await JournalStore(directoryURL: folder.appendingPathComponent("Journal")).write(entry: JournalEntry(
            planId: plan.planId, startedAt: Date(), status: .completed,
            stepOutcomes: outcomes, stepTrashedURLs: saved, restoreOutcomes: restored
        ))
        try await LedgerStore(directoryURL: folder.appendingPathComponent("Ledgers")).write(entry: LedgerEntry(
            planId: plan.planId, planHash: "fixture", executedAt: Date(), outcomes: [], recoveredBytes: 0
        ))
    }

    func fingerprint(_ url: URL) throws -> TargetFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try TargetFingerprint(dev: #require(attributes[.systemNumber] as? NSNumber).int32Value,
                                     ino: #require(attributes[.systemFileNumber] as? NSNumber).uint64Value,
                                     mtime: #require(attributes[.modificationDate] as? Date))
    }

    func makeBundle(_ bundle: URL, identifier: String) throws {
        let metadata = bundle.appendingPathComponent("Contents/Info.plist")
        let contents = metadata.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier],
                                           format: .xml, options: 0).write(to: metadata)
    }
}
