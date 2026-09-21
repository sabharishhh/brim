import XCTest
import Foundation
@testable import BrimCore
@testable import BrimProtocol
@testable import BrimService
@testable import BrimFixtures

final class UndoTests: XCTestCase {
    
    func testUndoRestoresAppAndRefusesIfOccupied() async throws {
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
        let resolved = await resolver.resolve(bundleURL: bundleURL)
        let intent = PlanIntent(type: .uninstall, subjectIdentity: resolved)
        
        let plan = try await service.plan(intent: intent)
        
        let hash = try plan.contentHash()
        let token = await realService.tokenStore.mintToken(planId: plan.planId, planHash: hash, requesterIdentity: intent.requesterIdentity)
        
        try await service.apply(planId: plan.planId, token: token)
        
        print("Plan targets:")
        for step in plan.steps {
            print("- \(step.target)")
        }
        
        let journalStore = JournalStore(directoryURL: journalStoreDir)
        let journal = try await journalStore.load(planId: plan.planId)
        print("Journal after apply: \(journal?.stepOutcomes ?? [:])")
        
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.path))
        
        // Verify history
        let history = try await service.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.planId, plan.planId)
        
        // First undo should succeed
        try await service.undo(planId: plan.planId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        
        // Wait, history should NOT be empty after undo since ledger is immutable
        let history2 = try await service.history()
        XCTAssertEqual(history2.count, 1) // Ledger entry persists
        
        let plan2 = try await service.plan(intent: intent)
        
        let hash2 = try plan2.contentHash()
        let token2 = await realService.tokenStore.mintToken(planId: plan2.planId, planHash: hash2, requesterIdentity: intent.requesterIdentity)
        try await service.apply(planId: plan2.planId, token: token2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.path))
        
        // Re-occupy the path
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "fake".write(to: bundleURL.appendingPathComponent("fake.txt"), atomically: true, encoding: .utf8)
        
        do {
            try await service.undo(planId: plan2.planId)
            XCTFail("Should have thrown error")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "BrimOps")
            XCTAssertEqual(nsError.code, 2)
        }
    }
}
