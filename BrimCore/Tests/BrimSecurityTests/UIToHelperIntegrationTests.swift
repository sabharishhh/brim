import XCTest
@testable import BrimService
import BrimProtocol
import BrimCore

final class UIToHelperIntegrationTests: XCTestCase {
    
    func testUIClickToBackgroundExecutionIntegration() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let appDir = tempDir.appendingPathComponent("TestApp.app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        
        let root = FileSystemRoot(rootURL: tempDir)
        let planStoreDir = tempDir.appendingPathComponent("Plans")
        let journalStoreDir = tempDir.appendingPathComponent("Journal")
        
        let realService = BrimService(
            root: root,
            brimAppURL: tempDir.appendingPathComponent("Brim.app"),
            planStoreDirectory: planStoreDir,
            journalStoreDirectory: journalStoreDir
        )
        
        let listener = NSXPCListener.anonymous()
        let delegate = BrimXPCListenerDelegate(service: realService, requireCodeSigning: false)
        listener.delegate = delegate
        listener.resume()
        
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: BrimXPCProtocol.self)
        connection.resume()
        
        let client = BrimXPCClient(connection: connection, requireCodeSigning: false)
        
        let identity = Identity(bundleID: "com.test.app", name: "TestApp")
        
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity, specificTarget: appDir)
        let plan = try await client.plan(intent: intent)
        
        guard plan.steps.count == 1 else {
            XCTFail("Expected 1 step, but got \(plan.steps.count). Excluded: \(plan.excludedItems.map { $0.reason })")
            return
        }
        XCTAssertEqual(plan.steps[0].target, appDir.path)
        
        // The client asks; only the service grants. This is the whole gate
        // in three lines: `BrimXPCClient` has no `grantApproval`, so the
        // token can only come from the process holding the service.
        let receipt = try await client.requestApproval(planId: plan.planId, requesterIdentity: "user")
        let token = try await realService.grantApproval(for: receipt)
        
        try await client.apply(planId: plan.planId, token: token)
        
        let verification = try await client.verify(planId: plan.planId)
        XCTAssertTrue(verification.success, "Background deletion failed via XPC")
        XCTAssertFalse(FileManager.default.fileExists(atPath: appDir.path))
    }
}
