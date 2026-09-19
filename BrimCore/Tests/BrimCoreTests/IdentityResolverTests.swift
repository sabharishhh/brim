import XCTest
@testable import BrimCore
@testable import BrimFixtures
import Foundation

final class IdentityResolverTests: XCTestCase {
    
    func testResolveFromFixtureTree() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        let gen = FixtureTreeGenerator(rootURL: tempRoot)
        try gen.generate()
        
        let fsRoot = FileSystemRoot(rootURL: tempRoot)
        let resolver = IdentityResolver(root: fsRoot)
        
        // 1. Sandboxed app
        let sandboxedURL = fsRoot.rootURL.appendingPathComponent("Applications/SandboxedApp.app")
        let sandboxedIdentity = await resolver.resolve(bundleURL: sandboxedURL)
        XCTAssertEqual(sandboxedIdentity.name, "SandboxedApp")
        XCTAssertEqual(sandboxedIdentity.bundleID, "com.brim.sandboxed")
        
        // 2. Launchd plist
        let daemonURL = fsRoot.rootURL.appendingPathComponent("Library/LaunchDaemons/com.brim.daemon.plist")
        let daemonIdentity = await resolver.resolve(launchdPlistURL: daemonURL)
        XCTAssertEqual(daemonIdentity.name, "com.brim.daemon")
        
        // 3. Receipt
        let receiptURL = fsRoot.rootURL.appendingPathComponent("Library/Receipts/com.brim.pkgproduct.bom")
        let receiptIdentity = await resolver.resolve(receiptURL: receiptURL)
        XCTAssertEqual(receiptIdentity.packageIdentifier, "com.brim.pkgproduct")
    }
}
