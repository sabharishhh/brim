import XCTest
@testable import BrimCore

final class PermissionAdvisorTests: XCTestCase {
    
    func testAdvisorCalculatesBlockersCorrectly() {
        let intent = PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: "com.test", name: "Test"))
        
        let step1 = Step(index: 0, kind: .trashPath, target: "/a", targetFingerprint: nil, tier: .A, evidence: "", expectedBytes: 0, capability: .needsHelper, reversible: true, costOfError: .medium, executionPhase: .appBundle)
        let step2 = Step(index: 1, kind: .trashPath, target: "/b", targetFingerprint: nil, tier: .A, evidence: "", expectedBytes: 0, capability: .needsFullDiskAccess, reversible: true, costOfError: .medium, executionPhase: .auxiliary)
        let step3 = Step(index: 2, kind: .trashPath, target: "/c", targetFingerprint: nil, tier: .A, evidence: "", expectedBytes: 0, capability: .refusedByOS, reversible: true, costOfError: .medium, executionPhase: .auxiliary)
        let step4 = Step(index: 3, kind: .trashPath, target: "/d", targetFingerprint: nil, tier: .A, evidence: "", expectedBytes: 0, capability: .ok, reversible: true, costOfError: .medium, executionPhase: .auxiliary)
        
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "1.0", osVersion: "14.0", intent: intent, steps: [step1, step2, step3, step4], excludedItems: [], expectedTotalBytes: 0)
        
        let advisor = PermissionAdvisor()
        let advice = advisor.advise(on: plan)
        
        XCTAssertTrue(advice.hasBlockers)
        XCTAssertTrue(advice.needsHelper)
        XCTAssertTrue(advice.needsFullDiskAccess)
        XCTAssertEqual(advice.refusedByOSCount, 1)
    }
}
