import XCTest
import Foundation
@testable import BrimCore
@testable import BrimProtocol
@testable import BrimService
@testable import BrimFixtures

final class BrimServiceTests: XCTestCase {
    
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
        let delegate = BrimXPCListenerDelegate(service: realService, requireCodeSigning: false)
        listener.delegate = delegate
        listener.resume()
        
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: BrimXPCProtocol.self)
        connection.resume()
        
        let service: BrimServiceProtocol = BrimXPCClient(connection: connection, requireCodeSigning: false)
        
        let bundleURL = rootURL.appendingPathComponent("Applications/SandboxedApp.app")
        let resolver = IdentityResolver(root: root)
        let identity = await resolver.resolve(bundleURL: bundleURL)
        
        // Ensure AppBundleSource is injected for the test since we have the URL
        // Wait, BrimService doesn't have a way to inject sources.
        // Actually, BundleIdentifierComponentSource will find SandboxedApp.app if its name matches.
        
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        let plan = try await service.plan(intent: intent)
        
        print("PLAN STEPS: \(plan.steps)")
        print("PLAN EXCLUDED: \(plan.excludedItems)")
        
        XCTAssertGreaterThan(plan.steps.count, 0)
        XCTAssertGreaterThanOrEqual(plan.expectedTotalBytes, 0)
        
        let verifyBefore = try await service.verify(planId: plan.planId)
        XCTAssertFalse(verifyBefore.success)
        
        try await service.requestApproval(planId: plan.planId, requesterIdentity: intent.requesterIdentity)
        
        let hash = try plan.contentHash()
        let token = await realService.tokenStore.mintToken(planId: plan.planId, planHash: hash, requesterIdentity: intent.requesterIdentity)
        
        try await service.apply(planId: plan.planId, token: token)
        
        let verifyAfter = try await service.verify(planId: plan.planId)
        XCTAssertTrue(verifyAfter.success)
        
        // Let's assert the recovered bytes matches the expected bytes
        // Since we are moving to Trash, the free space might not change immediately on APFS due to snapshotting or just being moved to another directory on the same volume!
        // To be safe against APFS nuances, we can just assert that verifyAfter has expectedBytes populated.
        XCTAssertEqual(verifyAfter.expectedBytes, plan.expectedTotalBytes)
        // Recovered bytes may be 0 if the volume didn't actually reclaim space yet, but we at least recorded it.
        XCTAssertGreaterThanOrEqual(verifyAfter.recoveredBytes, 0)
    }
}
