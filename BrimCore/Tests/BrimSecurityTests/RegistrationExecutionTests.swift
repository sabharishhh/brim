import BrimCore
import BrimOps
@testable import BrimPrivileged
import BrimProtocol
@testable import BrimService
import Foundation
import XCTest

final class RegistrationExecutionTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("brim-registration-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func fingerprint(_ path: String) throws -> TargetFingerprint {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return try TargetFingerprint(dev: XCTUnwrap(attrs[.systemNumber] as? NSNumber).int32Value,
                                     ino: XCTUnwrap(attrs[.systemFileNumber] as? NSNumber).uint64Value,
                                     mtime: XCTUnwrap(attrs[.modificationDate] as? Date))
    }

    private func plan(_ steps: [Step], payloads: [String: [String]]? = nil) -> Plan {
        Plan(planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
             intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(name: "Fixture")),
             steps: steps, excludedItems: [], expectedTotalBytes: 0, receiptPayloads: payloads)
    }

    func testMovedEmbeddedDeclarationDoesNotHideAStillLoadedJob() async {
        let record = Registration(kind: .launchdJob, identifier: "org.example.embedded.worker",
                                  label: "Worker", targetExists: false,
                                  recordPath: folder.appendingPathComponent("Removed.app/job.plist").path,
                                  evidence: "Saved embedded declaration.", namespace: "gui/501")
        let runtime = LaunchdRuntimeClient(stop: { _ in }, restore: { _ in }, observe: { label, namespace in
            XCTAssertEqual(label, record.identifier)
            XCTAssertEqual(namespace, "gui/501")
            return .present
        })
        let service = BrimService(root: FileSystemRoot(rootURL: folder, userName: "tester"),
                                  brimAppURL: folder.appendingPathComponent("Brim.app"),
                                  planStoreDirectory: folder.appendingPathComponent("Plans"),
                                  journalStoreDirectory: folder.appendingPathComponent("Journal"),
                                  launchdRuntime: runtime)
        let result = await service.recheckReviewedJobs(
            RegistrationVerification(capability: .launchdJob, observedAt: Date(),
                                     coverage: .available(.launchdJob), remaining: [], preserved: []),
            reviewed: [record], observedAt: Date()
        )
        XCTAssertEqual(result.remaining, [record])
        XCTAssertFalse(result.confirmedClear)
    }

    func testFailedJobStopKeepsItsDeclarationButIndependentRemovalContinues() async throws {
        // A missing Label formerly became the filename, a failed bootout was
        // ignored, and its declaration was deleted as though the job stopped.
        let declaration = folder.appendingPathComponent("wrong-label.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Program": "/bin/sleep"], format: .xml, options: 0)
            .write(to: declaration)
        let cache = folder.appendingPathComponent("cache")
        try Data([1]).write(to: cache)
        let steps = try [
            Step(
                index: 0,
                kind: .unloadLaunchdJob,
                target: declaration.path,
                targetFingerprint: fingerprint(declaration.path),
                tier: .A,
                evidence: "Fixture",
                expectedBytes: 0,
                capability: .ok,
                reversible: true,
                costOfError: .medium,
                executionPhase: .launchd
            ),
            Step(
                index: 1,
                kind: .removeLaunchdPlist,
                target: declaration.path,
                targetFingerprint: fingerprint(declaration.path),
                tier: .A,
                evidence: "Fixture",
                expectedBytes: 0,
                capability: .ok,
                reversible: false,
                costOfError: .low,
                executionPhase: .launchd,
                disposition: .delete
            ),
            Step(index: 2, kind: .trashPath, target: cache.path, targetFingerprint: fingerprint(cache.path),
                 tier: .A, evidence: "Fixture", expectedBytes: 1, capability: .ok, reversible: false,
                 costOfError: .low, disposition: .delete)
        ]
        let executor = Executor(journalStore: JournalStore(directoryURL: folder.appendingPathComponent("Journal")))
        let journal = try await executor.execute(plan: plan(steps))
        XCTAssertTrue(PathObservation.observe(declaration.path).isPresent)
        XCTAssertTrue(PathObservation.observe(cache.path).isAbsent)
        XCTAssertNotEqual(journal.stepOutcomes[0], "ok")
        XCTAssertNotEqual(journal.stepOutcomes[1], "ok")
        XCTAssertEqual(journal.stepOutcomes[2], "ok")
    }

    func testReceiptWithSurvivingPayloadNeverReachesTheHelper() async throws {
        let file = folder.appendingPathComponent("Other.app")
        try Data().write(to: file)
        let step = Step(index: 0, kind: .forgetReceipt, target: "org.example.suite", targetFingerprint: nil,
                        tier: .A, evidence: "Fixture", expectedBytes: 0, capability: .needsHelper,
                        reversible: false, costOfError: .medium, executionPhase: .registration)
        let executor = Executor(journalStore: JournalStore(directoryURL: folder.appendingPathComponent("Journal")))
        await executor.setPrivilegedReceiptForgetter { _ in
            XCTFail("A surviving payload must keep its installer record")
            return nil
        }
        let journal = try await executor.execute(plan: plan([step], payloads: [step.target: [file.path]]))
        XCTAssertEqual(journal.stepOutcomes[0], "receipt_kept_for_remaining_payload")
        let unknown = plan([step], payloads: [step.target: ["/Volumes/brim-disconnected-\(UUID())/file"]])
        let unknownJournal = try await executor.execute(plan: unknown)
        XCTAssertEqual(unknownJournal.stepOutcomes[0], "receipt_kept_for_remaining_payload")
    }

    func testAQualifiedAbsentPayloadReachesOnlyItsReviewedReceipt() async throws {
        let step = Step(index: 0, kind: .forgetReceipt, target: "org.example.fixture", targetFingerprint: nil,
                        tier: .A, evidence: "Fixture", expectedBytes: 0, capability: .needsHelper,
                        reversible: false, costOfError: .medium, executionPhase: .registration)
        let executor = Executor(journalStore: JournalStore(directoryURL: folder.appendingPathComponent("Journal")))
        await executor.setPrivilegedReceiptForgetter { identifier in
            XCTAssertEqual(identifier, "org.example.fixture")
            return nil
        }
        let reviewed = plan([step], payloads: [step.target: [folder.appendingPathComponent("gone").path]])
        let journal = try await executor.execute(plan: reviewed)
        XCTAssertEqual(journal.stepOutcomes[0], "ok")
        let legacy = try await executor.execute(plan: plan([step]))
        XCTAssertEqual(legacy.stepOutcomes[0], "receipt_kept_for_remaining_payload")
    }

    func testRechecksAppendObservationsWithoutReplacingExecutionReceipts() async throws {
        let store = JournalStore(directoryURL: folder.appendingPathComponent("Journal"))
        let id = UUID()
        let entry = JournalEntry(planId: id, startedAt: Date(), status: .completed, stepOutcomes: [0: "ok"])
        try await store.write(entry: entry)
        let first = VerificationResult(planId: id, expectedBytes: 1, recoveredBytes: 0, success: false,
                                       reason: "Could not check", remainingPaths: [folder.path])
        let second = VerificationResult(planId: id, expectedBytes: 1, recoveredBytes: 0, success: true)
        try await store.recordVerification(first)
        try await store.recordVerification(second)
        let saved = try await store.load(planId: id)
        let loaded = try XCTUnwrap(saved)
        XCTAssertEqual(loaded.stepOutcomes, [0: "ok"])
        XCTAssertEqual(loaded.verifications, [first, second])
        let text = try XCTUnwrap(String(data: JSONEncoder().encode(loaded), encoding: .utf8))
        XCTAssertFalse(text.contains("ApprovalToken"))
        XCTAssertFalse(text.contains("expiresAt"))
        let old = try JSONDecoder().decode(JournalEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertNil(old.verifications)
    }

    func testHelperRechecksThePayloadAndRejectsAmbiguousListings() throws {
        XCTAssertThrowsError(try PrivilegedReceiptRemoval.checkPayload(listing: "Other.app/Info.plist",
                                                                       prefix: "Applications", exists: { _ in true }))
        XCTAssertThrowsError(try PrivilegedReceiptRemoval.checkPayload(listing: "../Other.app/Info.plist",
                                                                       prefix: "Applications", exists: { _ in false }))
        XCTAssertThrowsError(try PrivilegedReceiptRemoval.checkPayload(listing: "",
                                                                       prefix: "Applications", exists: { _ in false }))
        XCTAssertThrowsError(try PrivilegedReceiptRemoval.checkPayload(listing: "Editor.app/Info.plist",
                                                                       prefix: "Applications",
                                                                       exists: { _ in throw NSError(
                                                                           domain: NSPOSIXErrorDomain,
                                                                           code: Int(EPERM)
                                                                       ) }))
        try PrivilegedReceiptRemoval.checkPayload(listing: "Editor.app/Info.plist", prefix: "Applications") { path in
            XCTAssertEqual(path, "/Applications/Editor.app/Info.plist")
            return false
        }
    }
}
