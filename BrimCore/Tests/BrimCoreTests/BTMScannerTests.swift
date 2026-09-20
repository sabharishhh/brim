import XCTest
@testable import BrimScan
@testable import BrimCore

final class BTMScannerTests: XCTestCase {
    func testBTMScannerEnrichesRecords() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        
        let fm = FileManager.default
        let appURL = rootURL.appendingPathComponent("Applications/SandboxedApp.app")
        try fm.createDirectory(at: appURL, withIntermediateDirectories: true)
        
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.brim.sandboxed</string>
            <key>CFBundleName</key>
            <string>SandboxedApp</string>
        </dict>
        </plist>
        """
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
        
        let root = FileSystemRoot(rootURL: rootURL)
        let scanner = BTMScanner(root: root)
        
        let dump = """
Items:
 #1:
                 UUID: C60CC267-53F9-447A-ABCB-37288CD56F64
                 Name: SandboxedApp
       Developer Name: (null)
                 Type: app (0x2)
                Flags: [  ] (0)
          Disposition: [disabled, allowed, not notified] (0x2)
           Identifier: 2.com.brim.sandboxed
                  URL: \(appURL.path)
           Generation: 0
    Bundle Identifier: com.brim.sandboxed
"""
        
        let enriched = await scanner.scan(dump: dump)
        XCTAssertEqual(enriched.count, 1)
        XCTAssertEqual(enriched[0].identity?.name, "SandboxedApp")
        XCTAssertEqual(enriched[0].identity?.bundleID, "com.brim.sandboxed")
        XCTAssertTrue(enriched[0].ownerExists)
        
        let missingDump = """
Items:
 #1:
                 UUID: C60CC267-53F9-447A-ABCB-37288CD56F64
                 Name: MissingApp
                  URL: \(rootURL.path)/Missing.app
    Bundle Identifier: com.brim.missing
"""
        let missingEnriched = await scanner.scan(dump: missingDump)
        XCTAssertEqual(missingEnriched.count, 1)
        XCTAssertEqual(missingEnriched[0].identity?.bundleID, "com.brim.missing")
        XCTAssertFalse(missingEnriched[0].ownerExists)
    }
}
