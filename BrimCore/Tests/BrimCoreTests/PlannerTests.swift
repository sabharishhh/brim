import XCTest
import Foundation
@testable import BrimCore

final class PlannerTests: XCTestCase {

    /// The Applications pane and the uninstall sheet describe the same row,
    /// and they used to describe it differently. The pane showed the sentence
    /// the evidence source wrote when it made the match, "A cache folder
    /// keyed to the bundle identifier". The sheet threw that away and rebuilt
    /// prose from the source's class name, giving "The file path exactly
    /// matches the application's unique identifier. It is highly probable
    /// this belongs to the application based on developer naming
    /// conventions." on four rows of one plan, word for word.
    ///
    /// The source's sentence is the better one because it knows which rule
    /// fired rather than only which type ran, so the plan carries it forward.
    func testAPlanStepSaysWhatTheEvidenceSourceSaid() throws {
        let url = URL(fileURLWithPath: "/tmp/planner_test/Library/Caches/com.test.app")
        let evidence = Evidence(
            url: url, tier: .B, mechanism: "BundleIdentifierComponentSource",
            humanSentence: "A cache folder keyed to the bundle identifier"
        )
        let item = EvaluatedItem(
            footprintItem: FootprintItem(evidence: evidence, sizeBytes: 10, capability: .ok),
            selection: .selected, costOfError: .low
        )
        let identity = Identity(bundleID: "com.test.app", name: "TestApp")
        let plan = Planner().createPlan(
            from: EvaluatedFootprint(identity: identity, items: [item]),
            intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
            engineVersion: "1.0"
        )

        let step = try XCTUnwrap(plan.steps.first { $0.kind == .trashPath })
        XCTAssertTrue(
            step.evidence.hasPrefix("A cache folder keyed to the bundle identifier"),
            "The plan discarded the source's own sentence: \(step.evidence)"
        )
        XCTAssertFalse(
            step.evidence.contains("highly probable"),
            "Tier B repeated as boilerplate under every row: \(step.evidence)"
        )
    }

    func testANameOnlyMatchStillSaysSoOnEveryRow() {
        // The one tier worth repeating. A C row rests on a shared name and
        // nothing else, which changes what somebody should do about it.
        let rendered = ExplanationRenderer().render(
            tier: .C, capability: .ok, mechanism: "HeuristicSource",
            found: "Shares a name with the application"
        )
        XCTAssertTrue(rendered.contains("name alone"), rendered)
    }

    func testASharedItemSaysItIsSharedWhateverElseIsTrue() {
        let rendered = ExplanationRenderer().render(
            tier: .S, capability: .ok, mechanism: "GroupContainerSource", found: "A shared container"
        )
        XCTAssertTrue(rendered.contains("leaves it alone"), rendered)
    }

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
        
        // A whole-app uninstall brackets the removal: grants cleared first
        // while the bundle exists, its registration retracted after it does
        // not. So there are two more steps than there are files.
        XCTAssertEqual(plan.steps.count, 3)

        let privacy = try XCTUnwrap(plan.steps.first { $0.kind == .resetPrivacyGrants })
        XCTAssertEqual(privacy.target, "test", "The reset is scoped to the bundle identifier")
        XCTAssertEqual(privacy.executionPhase, .privacyReset)
        XCTAssertFalse(privacy.reversible)

        let removal = try XCTUnwrap(plan.steps.first { $0.kind == .trashPath })
        XCTAssertEqual(removal.target, rootURL.appendingPathComponent("Test.app").path)
        XCTAssertEqual(removal.expectedBytes, 1024)

        // The ordering that matters: tccutil cannot resolve a bundle that has
        // already been deleted, so the reset must come first.
        let order = plan.executionOrderedSteps.map(\.kind)
        XCTAssertEqual(order.firstIndex(of: .resetPrivacyGrants), 0,
                       "Privacy grants must be cleared before anything is removed")
        
        XCTAssertEqual(plan.excludedItems.count, 2)
        XCTAssertEqual(plan.excludedItems[0].reason, "Brim refused to modify this item to ensure system stability.")
        XCTAssertEqual(plan.excludedItems[1].reason, "You opted to keep this item, or it was unselected by default due to low confidence.")
        
        XCTAssertEqual(plan.expectedTotalBytes, 1024)
    }

    func testAWholeAppUninstallRetractsTheLaunchServicesRegistration() throws {
        // Deleting a bundle leaves its Launch Services record behind: the app
        // keeps appearing in "Open With" and keeps claiming its document
        // types. Removing the files is not the whole uninstall.
        let rootURL = URL(fileURLWithPath: "/tmp/planner_test")
        let identity = Identity(bundleID: "com.test.app", name: "TestApp")
        let appURL = rootURL.appendingPathComponent("Test.app")

        let evidence = Evidence(url: appURL, tier: .A, mechanism: "test", humanSentence: "test")
        let item = EvaluatedItem(
            footprintItem: FootprintItem(evidence: evidence, sizeBytes: 1024, capability: .ok),
            selection: .selected,
            costOfError: .low
        )
        let footprint = EvaluatedFootprint(identity: identity, items: [item])

        let plan = Planner().createPlan(
            from: footprint,
            intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
            engineVersion: "1.0"
        )

        let unregister = try XCTUnwrap(
            plan.steps.first { $0.kind == .unregisterLaunchServices },
            "A whole-app uninstall must retract the registration"
        )
        XCTAssertEqual(unregister.target, appURL.path, "Scoped to the bundle, never a database rebuild")
        XCTAssertEqual(unregister.executionPhase, .registration)
        XCTAssertEqual(unregister.expectedBytes, 0, "A registration is not disk space")

        XCTAssertEqual(plan.executionOrderedSteps.last?.kind, .unregisterLaunchServices,
                       "Launch Services re-registers a bundle it can still see, so this runs last")
    }

    func testTidyingSpecificItemsDoesNotTouchTheRegistration() throws {
        // Picking one leftover out of the queue is not an uninstall. It must
        // not unregister the application that still exists.
        let rootURL = URL(fileURLWithPath: "/tmp/planner_test")
        let identity = Identity(bundleID: "com.test.app", name: "TestApp")
        let cacheURL = rootURL.appendingPathComponent("Caches/com.test.app")

        let evidence = Evidence(url: cacheURL, tier: .B, mechanism: "test", humanSentence: "test")
        let item = EvaluatedItem(
            footprintItem: FootprintItem(evidence: evidence, sizeBytes: 10, capability: .ok),
            selection: .selected,
            costOfError: .low
        )
        let footprint = EvaluatedFootprint(identity: identity, items: [item])

        let plan = Planner().createPlan(
            from: footprint,
            intent: PlanIntent(type: .uninstall, subjectIdentity: identity, specificTargets: [cacheURL]),
            engineVersion: "1.0"
        )

        XCTAssertFalse(plan.steps.contains { $0.kind == .unregisterLaunchServices })
        XCTAssertFalse(plan.steps.contains { $0.kind == .resetPrivacyGrants })
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
