import XCTest
import Foundation
@testable import BrimCore

final class PlannerTests: XCTestCase {
    
    func testPlannerCreatesValidPlan() throws {
        let rootURL = URL(fileURLWithPath: "/tmp/planner_test")
        let identity = Identity(bundleID: "test", name: "test")
        
        let evidence = Evidence(url: rootURL.appendingPathComponent("Test.app"), tier: .A, mechanism: "test", humanSentence: "test")
        let fpItem = FootprintItem(evidence: evidence, sizeBytes: 1024, capability: .ok)
        
        let evaluatedItem1 = EvaluatedItem(footprintItem: fpItem, selection: .selected, costOfError: .low)
        let evaluatedItem2 = EvaluatedItem(footprintItem: fpItem, selection: .excluded(reason: "Brim refused to modify this item to ensure system stability."), costOfError: .high)
        let evaluatedItem3 = EvaluatedItem(footprintItem: fpItem, selection: .unselected, costOfError: .medium)
        
        let evaluatedFootprint = EvaluatedFootprint(identity: identity, items: [evaluatedItem1, evaluatedItem2, evaluatedItem3])
        
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        let planner = Planner()
        
        let plan = planner.createPlan(from: evaluatedFootprint, intent: intent, engineVersion: "1.0")
        
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps[0].target, rootURL.appendingPathComponent("Test.app").path)
        XCTAssertEqual(plan.steps[0].expectedBytes, 1024)
        
        XCTAssertEqual(plan.excludedItems.count, 2)
        XCTAssertEqual(plan.excludedItems[0].reason, "Brim refused to modify this item to ensure system stability.")
        XCTAssertEqual(plan.excludedItems[1].reason, "You opted to keep this item, or it was unselected by default due to low confidence.")
        
        XCTAssertEqual(plan.expectedTotalBytes, 1024)
    }
    
    func testArchiveOnlyDoesNotGenerateTrashSteps() throws {
        let rootURL = URL(fileURLWithPath: "/tmp/planner_test")
        let identity = Identity(bundleID: "test", name: "test")
        let destURL = URL(fileURLWithPath: "/tmp/archive_dest")
        
        let evidence = Evidence(url: rootURL.appendingPathComponent("Test.app"), tier: .A, mechanism: "test", humanSentence: "test")
        let fpItem = FootprintItem(evidence: evidence, sizeBytes: 1024, capability: .ok)
        let evaluatedItem = EvaluatedItem(footprintItem: fpItem, selection: .selected, costOfError: .low)
        let evaluatedFootprint = EvaluatedFootprint(identity: identity, items: [evaluatedItem])
        
        let intent = PlanIntent(type: .archive, subjectIdentity: identity, destinationTarget: destURL, archiveAndUninstall: false)
        let planner = Planner()
        let plan = planner.createPlan(from: evaluatedFootprint, intent: intent, engineVersion: "1.0")
        
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps[0].kind, .archivePath)
        XCTAssertEqual(plan.steps[0].executionPhase, .archive)
    }
    
    func testArchiveAndUninstallGeneratesBoth() throws {
        let rootURL = URL(fileURLWithPath: "/tmp/planner_test")
        let identity = Identity(bundleID: "test", name: "test")
        let destURL = URL(fileURLWithPath: "/tmp/archive_dest")
        
        let evidence = Evidence(url: rootURL.appendingPathComponent("Test.app"), tier: .A, mechanism: "test", humanSentence: "test")
        let fpItem = FootprintItem(evidence: evidence, sizeBytes: 1024, capability: .ok)
        let evaluatedItem = EvaluatedItem(footprintItem: fpItem, selection: .selected, costOfError: .low)
        let evaluatedFootprint = EvaluatedFootprint(identity: identity, items: [evaluatedItem])
        
        let intent = PlanIntent(type: .archive, subjectIdentity: identity, destinationTarget: destURL, archiveAndUninstall: true)
        let planner = Planner()
        let plan = planner.createPlan(from: evaluatedFootprint, intent: intent, engineVersion: "1.0")
        
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].kind, .archivePath)
        XCTAssertEqual(plan.steps[1].kind, .trashPath)
    }

    func testEveryRowInPlanHasASentence() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/fake_root")
        let identity = Identity(bundleID: "com.test.app", name: "TestApp")
        let evidence = Evidence(url: rootURL.appendingPathComponent("Test.app"), tier: .A, mechanism: "AppBundleSource", humanSentence: "The application bundle itself")
        let footprintItem = FootprintItem(evidence: evidence, sizeBytes: 100, capability: .ok)
        let evaluatedItem = EvaluatedItem(footprintItem: footprintItem, selection: .selected, costOfError: .low)
        let evaluatedFootprint = EvaluatedFootprint(identity: identity, items: [evaluatedItem])
        
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        let planner = Planner()
        let plan = planner.createPlan(from: evaluatedFootprint, intent: intent, engineVersion: "1.0")
        
        for step in plan.steps {
            XCTAssertFalse(step.evidence.isEmpty, "Step evidence sentence must not be empty.")
            XCTAssertNotEqual(step.evidence, "System", "Sentence must be human-readable prose, not a raw constant.")
        }
    }
}
