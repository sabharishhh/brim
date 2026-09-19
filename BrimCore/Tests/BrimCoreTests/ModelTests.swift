import XCTest
import Foundation
@testable import BrimCore

final class ModelTests: XCTestCase {
    
    func testPlanCanonicalEncoding() throws {
        let fingerprint = TargetFingerprint(dev: 1, ino: 2, mtime: Date(timeIntervalSince1970: 0))
        let step = Step(
            index: 0,
            kind: .trashPath,
            target: "/fake/path",
            targetFingerprint: fingerprint,
            tier: .A,
            evidence: "Because I said so",
            expectedBytes: 1024,
            capability: .ok,
            reversible: true,
            costOfError: .low
        )
        
        let plan = Plan(
            planId: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
            createdAt: Date(timeIntervalSince1970: 0),
            engineVersion: "1.0",
            osVersion: "15.0",
            intentType: "uninstall",
            intentSubject: "app",
            requesterKind: "cli",
            requesterIdentity: "test",
            steps: [step],
            expectedTotalBytes: 1024
        )
        
        let data1 = try plan.canonicalData()
        let data2 = try plan.canonicalData()
        
        // Assert determinism
        XCTAssertEqual(data1, data2)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Plan.self, from: data1)
        XCTAssertEqual(plan.planId, decoded.planId)
        XCTAssertEqual(plan.steps.count, decoded.steps.count)
        XCTAssertEqual(plan.steps[0].target, decoded.steps[0].target)
    }
}
