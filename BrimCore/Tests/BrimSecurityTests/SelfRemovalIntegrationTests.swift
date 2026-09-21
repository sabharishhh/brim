import XCTest
@testable import BrimService
import BrimProtocol
import BrimCore

final class SelfRemovalIntegrationTests: XCTestCase {
    func testBrimCanUninstallItself() async throws {
        // Setup mock footprint
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let root = FileSystemRoot(rootURL: tempDir)
        
        let appsDir = tempDir.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        
        let brimAppDir = appsDir.appendingPathComponent("Brim.app")
        try FileManager.default.createDirectory(at: brimAppDir, withIntermediateDirectories: true)
        
        let launchAgentsDir = tempDir.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        let agentPlist = launchAgentsDir.appendingPathComponent("devplaceholder.PJ52YXEB.brim.plist")
        
        // Write valid plist
        let plistString = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>devplaceholder.PJ52YXEB.brim</string>
        </dict>
        </plist>
        """
        try plistString.write(to: agentPlist, atomically: true, encoding: .utf8)
        
        let planStoreDir = tempDir.appendingPathComponent("Plans")
        let journalStoreDir = tempDir.appendingPathComponent("Journal")
        
        let realService = BrimService(
            root: root,
            brimAppURL: brimAppDir,
            planStoreDirectory: planStoreDir,
            journalStoreDirectory: journalStoreDir
        )
        
        let listener = NSXPCListener.anonymous()
        let delegate = BrimXPCListenerDelegate(service: realService, accepting: .sameProcessAnonymous)
        listener.delegate = delegate
        listener.resume()
        
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: BrimXPCProtocol.self)
        let client = try BrimXPCClient(connection: connection, expecting: .sameProcessAnonymous)
        
        let identity = Identity(bundleID: "devplaceholder.PJ52YXEB.brim", teamID: "PJ52YXEB", name: "Brim")
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        
        let plan = try await client.plan(intent: intent)
        
        let appExistsInPlan = plan.steps.contains { $0.target.contains("Brim.app") }
        XCTAssertTrue(appExistsInPlan, "Brim app must be included in the self-uninstall plan.")
        
        let plistExistsInPlan = plan.steps.contains { $0.target.contains("devplaceholder.PJ52YXEB.brim.plist") }
        XCTAssertTrue(plistExistsInPlan, "Agent plist must be included. Excluded: \(plan.excludedItems.map { $0.reason })")
        
        let receipt = try await client.requestApproval(planId: plan.planId, requesterIdentity: "user")
        let token = try await realService.grantApproval(for: receipt)
        try await client.apply(planId: plan.planId, token: token)
        
        let verification = try await client.verify(planId: plan.planId)
        XCTAssertTrue(verification.success, "Self-uninstall failed verification.")
        
        XCTAssertFalse(FileManager.default.fileExists(atPath: brimAppDir.path), "Brim app was not deleted.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentPlist.path), "Agent plist was not deleted.")
    }
}
