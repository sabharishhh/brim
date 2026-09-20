import XCTest
import Foundation
@testable import BrimCore
@testable import BrimService

final class VerifierTests: XCTestCase {
    
    func testVerifierPinnedBytes() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        let planStoreDir = tempDir.appendingPathComponent("Plans")
        let journalStoreDir = tempDir.appendingPathComponent("Journals")
        
        let root = FileSystemRoot(rootURL: rootURL)
        let brimAppURL = rootURL.appendingPathComponent("Brim.app")
        let service = BrimService(root: root, brimAppURL: brimAppURL, planStoreDirectory: planStoreDir, journalStoreDirectory: journalStoreDir)
        
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        
        // Let's create a dummy plan directly in the store
        let bundleURL = rootURL.appendingPathComponent("Pinned.app")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let pinnedFile = bundleURL.appendingPathComponent("data.bin")
        try Data(repeating: 0, count: 1024).write(to: pinnedFile)
        
        // Pinned - we make it immutable
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: bundleURL.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: bundleURL.path)
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let intent = PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: "com.pinned", name: "Pinned"))
        // Wait, IdentityResolver won't find Pinned.app because it's not a real app (no Info.plist).
        // Let's just create a manual plan and put it in the store.
        
        let manualPlan = Plan(
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
        
        // Add to plan store (we have to use internal access or just use plan store)
        // Actually, we can use BrimService to apply it if we inject it, but BrimService only loads from planStore.
        // Let's create a PlanStore manually
        let planStore = PlanStore(directoryURL: planStoreDir)
        try await planStore.save(plan: manualPlan)
        
        let hash = try manualPlan.contentHash()
        let token = await service.mintTokenForTest(planId: manualPlan.planId, planHash: hash, requesterIdentity: intent.requesterIdentity)
        
        // Apply will fail to delete Pinned.app because it's immutable
        try await service.apply(planId: manualPlan.planId, token: token)
        
        let result = try await service.verify(planId: manualPlan.planId)
        
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.expectedBytes, 1024)
        XCTAssertEqual(result.recoveredBytes, 0)
        XCTAssertNotNil(result.reason)
        XCTAssertTrue(result.reason!.contains("1 targets still remain"))
    }
}
