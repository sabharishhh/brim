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
        
        let identity = Identity(bundleID: "test", name: "test")
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        let excluded = ExcludedItem(target: "/fake/path/excluded", reason: "Test")
        
        let plan = Plan(
            planId: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
            createdAt: Date(timeIntervalSince1970: 0),
            engineVersion: "1.0",
            osVersion: "15.0",
            intent: intent,
            steps: [step],
            excludedItems: [excluded],
            expectedTotalBytes: 1024
        )
        
        let data1 = try plan.canonicalData()
        let data2 = try plan.canonicalData()
        
        // Assert determinism
        XCTAssertEqual(data1, data2)
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom({ decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            guard let date = formatter.date(from: dateStr) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateStr)")
            }
            return date
        })
        
        let decoded = try decoder.decode(Plan.self, from: data1)
        XCTAssertEqual(plan.planId, decoded.planId)
        XCTAssertEqual(plan.steps.count, decoded.steps.count)
        XCTAssertEqual(plan.steps[0].target, decoded.steps[0].target)
        XCTAssertEqual(plan.intent.subjectIdentity.name, decoded.intent.subjectIdentity.name)
        
        let hash1 = try plan.contentHash()
        XCTAssertFalse(hash1.isEmpty)
    }
}
