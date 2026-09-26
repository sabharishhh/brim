import BrimCore
import BrimProtocol
@testable import BrimService
import XCTest

final class SelfRemovalIntegrationTests: XCTestCase {
    private func makeBundle(in applications: URL) throws -> URL {
        let bundle = applications.appendingPathComponent("Brim.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "devplaceholder.PJ52YXEB.brim"],
            format: .xml, options: 0
        )
        try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    func testBrimCanUninstallItself() async throws {
        // Setup mock footprint
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let root = FileSystemRoot(rootURL: tempDir)

        let appsDir = tempDir.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)

        let brimAppDir = try makeBundle(in: appsDir)

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

        XCTAssertTrue(plan.steps.contains { $0.target.contains("Brim.app") })

        let plistExistsInPlan = plan.steps.contains { $0.target.contains("devplaceholder.PJ52YXEB.brim.plist") }
        XCTAssertTrue(plistExistsInPlan, "Agent plist must be included. Excluded: \(plan.excludedItems.map(\.reason))")

        let receipt = try await client.requestApproval(planId: plan.planId, requesterIdentity: "user")
        let token = try await realService.grantApproval(for: receipt)
        try await client.apply(planId: plan.planId, token: token)

        let verification = try await client.verify(planId: plan.planId)
        XCTAssertTrue(verification.remainingPaths.isEmpty, "Self-uninstall left selected files behind.")
        XCTAssertFalse(verification.success, "The fixture's unregistered bundle cannot pass tccutil.")
        XCTAssertEqual(verification.followUpActions, [.restoreAppForPrivacyReset])

        XCTAssertFalse(FileManager.default.fileExists(atPath: brimAppDir.path), "Brim app was not deleted.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentPlist.path), "Agent plist was not deleted.")
    }
}
