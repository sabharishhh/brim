import XCTest
import Foundation
@testable import BrimCore

final class PlanStoreTests: XCTestCase {
    
    func testPlanRoundTripsThroughDiskUnchanged() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let store = PlanStore(directoryURL: tempDir)
        
        let identity = Identity(bundleID: "test", name: "test")
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        
        let plan = Plan(
            planId: UUID(),
            createdAt: Date(),
            engineVersion: "1.0",
            osVersion: "15.0",
            intent: intent,
            steps: [],
            excludedItems: [],
            expectedTotalBytes: 0
        )
        
        let originalHash = try plan.contentHash()
        
        // Save to disk
        try await store.save(plan: plan)
        
        // Load from disk
        let loadedPlan = try await store.load(planId: plan.planId)
        let loadedHash = try loadedPlan.contentHash()
        
        XCTAssertEqual(originalHash, loadedHash)
        XCTAssertEqual(plan.planId, loadedPlan.planId)
        XCTAssertEqual(plan.engineVersion, loadedPlan.engineVersion)
    }
}
