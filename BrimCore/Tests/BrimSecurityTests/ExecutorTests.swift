import XCTest
import Foundation
@testable import BrimCore
@testable import BrimService

final class ExecutorTests: XCTestCase {
    
    func testExecutorPartialFailureLeavesBundle() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journalStoreDir = tempDir.appendingPathComponent("Journals")
        let journalStore = JournalStore(directoryURL: journalStoreDir)
        let executor = Executor(journalStore: journalStore)
        
        let bundleURL = tempDir.appendingPathComponent("App.app")
        let blockedURL = tempDir.appendingPathComponent("Blocked.txt")
        let okURL = tempDir.appendingPathComponent("Ok.txt")
        
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "blocked".write(to: blockedURL, atomically: true, encoding: .utf8)
        try "ok".write(to: okURL, atomically: true, encoding: .utf8)
        
        // Lock the blocked file so it can't be deleted
        let attributes: [FileAttributeKey: Any] = [.immutable: true]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: blockedURL.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blockedURL.path)
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Create plan
        let intent = PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: "com.app", name: "App"))
        let plan = Plan(
            planId: UUID(),
            createdAt: Date(),
            engineVersion: "1",
            osVersion: "1",
            intent: intent,
            steps: [
                Step(index: 0, kind: .trashPath, target: bundleURL.path, targetFingerprint: nil, tier: .A, evidence: "app", expectedBytes: 0, capability: .ok, reversible: true, costOfError: .low),
                Step(index: 1, kind: .trashPath, target: blockedURL.path, targetFingerprint: nil, tier: .A, evidence: "blocked", expectedBytes: 0, capability: .ok, reversible: true, costOfError: .low),
                Step(index: 2, kind: .trashPath, target: okURL.path, targetFingerprint: nil, tier: .A, evidence: "ok", expectedBytes: 0, capability: .ok, reversible: true, costOfError: .low)
            ],
            excludedItems: [],
            expectedTotalBytes: 0
        )
        
        let journal = try await executor.execute(plan: plan)
        
        // blocked should fail, meaning status is .partial
        XCTAssertEqual(journal.status, PlanStatus.partial)
        
        // ok should be deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: okURL.path))
        XCTAssertEqual(journal.stepOutcomes[2], "ok")
        
        // App bundle should be skipped
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        XCTAssertEqual(journal.stepOutcomes[0], "skipped_due_to_prior_failures")
    }
}
