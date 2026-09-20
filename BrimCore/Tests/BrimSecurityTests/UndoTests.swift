import XCTest
import Foundation
@testable import BrimCore
@testable import BrimService
@testable import BrimFixtures

final class UndoTests: XCTestCase {
    
    func testUndoRestoresAppAndRefusesIfOccupied() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        let planStoreDir = tempDir.appendingPathComponent("Plans")
        let journalStoreDir = tempDir.appendingPathComponent("Journals")
        
        let gen = FixtureTreeGenerator(rootURL: rootURL)
        defer { gen.destroy() }
        try gen.generate()
        
        let root = FileSystemRoot(rootURL: rootURL)
        let brimAppURL = rootURL.appendingPathComponent("Brim.app")
        let service = BrimService(root: root, brimAppURL: brimAppURL, planStoreDirectory: planStoreDir, journalStoreDirectory: journalStoreDir)
        
        let bundleURL = rootURL.appendingPathComponent("Applications/SandboxedApp.app")
        let resolver = IdentityResolver(root: root)
        let resolved = await resolver.resolve(bundleURL: bundleURL)
        let intent = PlanIntent(type: .uninstall, subjectIdentity: resolved)
        
        let plan = Plan(
            planId: UUID(),
            createdAt: Date(),
            engineVersion: "1",
            osVersion: "1",
            intent: intent,
            steps: [
                Step(index: 0, kind: .trashPath, target: bundleURL.path, targetFingerprint: nil, tier: .A, evidence: "app", expectedBytes: 1024, capability: .ok, reversible: true, costOfError: .low)
            ],
            excludedItems: [],
            expectedTotalBytes: 1024
        )
        
        let planStore = PlanStore(directoryURL: planStoreDir)
        try await planStore.save(plan: plan)
        
        try await service.requestApproval(planId: plan.planId, requesterIdentity: intent.requesterIdentity)
        let hash = try plan.contentHash()
        let token = await service.mintTokenForTest(planId: plan.planId, planHash: hash, requesterIdentity: intent.requesterIdentity)
        
        try await service.apply(planId: plan.planId, token: token)
        
        print("Plan targets:")
        for step in plan.steps {
            print("- \(step.target)")
        }
        
        let journalStore = JournalStore(directoryURL: journalStoreDir)
        let journal = try await journalStore.load(planId: plan.planId)
        print("Journal after apply: \(journal?.stepOutcomes ?? [:])")
        
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.path))
        
        // Verify history
        let history = try await service.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.planId, plan.planId)
        
        // First undo should succeed
        try await service.undo(planId: plan.planId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        
        // Wait, history should be empty after undo?
        let history2 = try await service.history()
        XCTAssertEqual(history2.count, 0) // because we deleted the journal
        
        let plan2 = Plan(
            planId: UUID(),
            createdAt: Date(),
            engineVersion: "1",
            osVersion: "1",
            intent: intent,
            steps: [
                Step(index: 0, kind: .trashPath, target: bundleURL.path, targetFingerprint: nil, tier: .A, evidence: "app", expectedBytes: 1024, capability: .ok, reversible: true, costOfError: .low)
            ],
            excludedItems: [],
            expectedTotalBytes: 1024
        )
        try await planStore.save(plan: plan2)
        
        try await service.requestApproval(planId: plan2.planId, requesterIdentity: intent.requesterIdentity)
        let hash2 = try plan2.contentHash()
        let token2 = await service.mintTokenForTest(planId: plan2.planId, planHash: hash2, requesterIdentity: intent.requesterIdentity)
        try await service.apply(planId: plan2.planId, token: token2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.path))
        
        // Re-occupy the path
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "fake".write(to: bundleURL.appendingPathComponent("fake.txt"), atomically: true, encoding: .utf8)
        
        do {
            try await service.undo(planId: plan2.planId)
            XCTFail("Should have thrown error")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "BrimService")
            XCTAssertEqual(nsError.code, 2)
        }
    }
}
