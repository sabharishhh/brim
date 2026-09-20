import XCTest
@testable import BrimService
import BrimProtocol
import BrimCore

final class XPCAuthenticationTests: XCTestCase {
    
    func testCodeSigningRejectsUnsignedTestRunner() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let root = FileSystemRoot(rootURL: tempDir)
        let brimAppURL = tempDir.appendingPathComponent("Brim.app")
        let planStoreDir = tempDir.appendingPathComponent("Plans")
        let journalStoreDir = tempDir.appendingPathComponent("Journal")
        
        let realService = BrimService(
            root: root,
            brimAppURL: brimAppURL,
            planStoreDirectory: planStoreDir,
            journalStoreDirectory: journalStoreDir
        )
        
        let listener = NSXPCListener.anonymous()
        let delegate = BrimXPCListenerDelegate(service: realService, requireCodeSigning: true)
        listener.delegate = delegate
        listener.resume()
        
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: BrimXPCProtocol.self)
        connection.resume()
        
        let client = BrimXPCClient(connection: connection, requireCodeSigning: true)
        let identity = Identity(bundleID: "com.apple.Safari", teamID: "EQHXZ8M8AV", name: "Safari")
        
        do {
            _ = try await client.inspect(identity: identity)
            XCTFail("Expected XPC connection to be rejected due to code signing requirement!")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, NSCocoaErrorDomain)
            XCTAssertEqual(error.code, 4097) // NSXPCConnectionInterrupted
        }
    }


    func testNoProcessIdentifierUsage() throws {
        // Assert that 'processIdentifier' is never used for XPC auth
        let sourcePath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // BrimSecurityTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // BrimCore
            .appendingPathComponent("Sources")
        
        guard let enumerator = FileManager.default.enumerator(at: sourcePath, includingPropertiesForKeys: nil) else {
            XCTFail("Failed to enumerate sources")
            return
        }
        
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "swift" {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                if content.contains("processIdentifier") {
                    XCTFail("Found forbidden usage of processIdentifier in \(fileURL.lastPathComponent)")
                }
            }
        }
    }
}
