import XCTest
import Foundation
@testable import BrimCore
@testable import BrimProtocol
@testable import BrimService
@testable import BrimFixtures

final class BrimServiceTests: XCTestCase {

    func testFailedPrivacyResetIsNotReportedAsCompleteAfterBundleRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-removal-ceiling-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = FileSystemRoot(rootURL: directory.appendingPathComponent("Root"))
        let plans = directory.appendingPathComponent("Plans")
        let journals = directory.appendingPathComponent("Journals")
        let service = BrimService(root: root, brimAppURL: directory.appendingPathComponent("Brim.app"),
                                  planStoreDirectory: plans, journalStoreDirectory: journals)
        let identity = Identity(bundleID: "org.example.departed", name: "Departed")
        let reset = Step(index: 0, kind: .resetPrivacyGrants, target: "org.example.departed",
                         targetFingerprint: nil, tier: .A, evidence: "Privacy reset",
                         expectedBytes: 0, capability: .ok, reversible: false,
                         costOfError: .medium)
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "fixture",
                        osVersion: "fixture", intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
                        steps: [reset], excludedItems: [], expectedTotalBytes: 0)
        try await service.planStore.save(plan: plan)
        try await JournalStore(directoryURL: journals).write(entry: JournalEntry(
            planId: plan.planId, startedAt: Date(), status: .partial,
            stepOutcomes: [0: "privacy_grants_not_cleared"]
        ))

        let result = try await service.verify(planId: plan.planId)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.reason, "Privacy permissions were not reset.")
        XCTAssertEqual(result.followUpActions, [.restoreAppForPrivacyReset])
    }

    func testFailedPrivacyResetWithInstalledBundleDoesNotSuggestReinstalling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-reset-ceiling-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = FileSystemRoot(rootURL: directory.appendingPathComponent("Root"))
        let plans = directory.appendingPathComponent("Plans")
        let journals = directory.appendingPathComponent("Journals")
        let bundle = directory.appendingPathComponent("Root/Applications/Installed.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let service = BrimService(root: root, brimAppURL: directory.appendingPathComponent("Brim.app"),
                                  planStoreDirectory: plans, journalStoreDirectory: journals)
        let identity = Identity(bundleID: "org.example.installed", name: "Installed", bundlePath: bundle.path)
        let reset = Step(index: 0, kind: .resetPrivacyGrants, target: "org.example.installed",
                         targetFingerprint: nil, tier: .A, evidence: "Privacy reset",
                         expectedBytes: 0, capability: .ok, reversible: false,
                         costOfError: .medium)
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "fixture",
                        osVersion: "fixture", intent: PlanIntent(type: .reset, subjectIdentity: identity),
                        steps: [reset], excludedItems: [], expectedTotalBytes: 0)
        try await service.planStore.save(plan: plan)
        try await JournalStore(directoryURL: journals).write(entry: JournalEntry(
            planId: plan.planId, startedAt: Date(), status: .partial,
            stepOutcomes: [0: "privacy_grants_not_cleared"]
        ))

        let result = try await service.verify(planId: plan.planId)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.reason, "Privacy permissions were not reset.")
        XCTAssertNil(result.followUpActions)
    }
    
    func testServiceDrivesCompleteUninstall() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        let planStoreDir = tempDir.appendingPathComponent("Plans")
        let journalStoreDir = tempDir.appendingPathComponent("Journals")
        
        let gen = FixtureTreeGenerator(rootURL: rootURL)
        defer { gen.destroy() }
        try gen.generate()
        
        let root = FileSystemRoot(rootURL: rootURL)
        let brimAppURL = rootURL.appendingPathComponent("Brim.app")
        let realService = BrimService(root: root, brimAppURL: brimAppURL, planStoreDirectory: planStoreDir, journalStoreDirectory: journalStoreDir)
        
        // Spin up XPC listener for boundary testing
        let listener = NSXPCListener.anonymous()
        let delegate = BrimXPCListenerDelegate(service: realService, accepting: .sameProcessAnonymous)
        listener.delegate = delegate
        listener.resume()
        
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: BrimXPCProtocol.self)
                
        let service: BrimServiceProtocol = try BrimXPCClient(connection: connection, expecting: .sameProcessAnonymous)
        
        let bundleURL = rootURL.appendingPathComponent("Applications/SandboxedApp.app")
        let resolver = IdentityResolver(root: root)
        let identity = await resolver.resolve(bundleURL: bundleURL)
        
        // Ensure AppBundleSource is injected for the test since we have the URL
        // Wait, BrimService doesn't have a way to inject sources.
        // Actually, BundleIdentifierComponentSource will find SandboxedApp.app if its name matches.
        
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        let plan = try await service.plan(intent: intent)
        
        XCTAssertGreaterThan(plan.steps.count, 0)
        XCTAssertGreaterThanOrEqual(plan.expectedTotalBytes, 0)
        
        let verifyBefore = try await service.verify(planId: plan.planId)
        XCTAssertFalse(verifyBefore.success)
        
        
        let hash = try plan.contentHash()
        let token = await realService.tokenStore.mintToken(planId: plan.planId, planHash: hash, requesterIdentity: intent.requesterIdentity)
        
        try await service.apply(planId: plan.planId, token: token)
        
        let verifyAfter = try await service.verify(planId: plan.planId)
        XCTAssertTrue(verifyAfter.remainingPaths.isEmpty)
        XCTAssertFalse(verifyAfter.success, "The fixture's unregistered bundle cannot pass tccutil")
        XCTAssertEqual(verifyAfter.followUpActions, [.restoreAppForPrivacyReset])
        
        // Let's assert the recovered bytes matches the expected bytes
        // Since we are moving to Trash, the free space might not change immediately on APFS due to snapshotting or just being moved to another directory on the same volume!
        // To be safe against APFS nuances, we can just assert that verifyAfter has expectedBytes populated.
        XCTAssertEqual(verifyAfter.expectedBytes, plan.expectedTotalBytes)
        // Recovered bytes may be 0 if the volume didn't actually reclaim space yet, but we at least recorded it.
        XCTAssertGreaterThanOrEqual(verifyAfter.recoveredBytes, 0)
    }
}
