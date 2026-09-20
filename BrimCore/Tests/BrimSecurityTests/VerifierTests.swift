import XCTest
import Foundation
@testable import BrimCore
@testable import BrimService

final class VerifierTests: XCTestCase {
    
    func testVerifierPinnedBytes() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        let planStoreDir = tempDir.appendingPathComponent("Plans")
        let journalStoreDir = tempDir.appendingPathComponent("Journals")
        
        let root = FileSystemRoot(rootURL: rootURL)
        let brimAppURL = rootURL.appendingPathComponent("Brim.app")
        let service = BrimService(root: root, brimAppURL: brimAppURL, planStoreDirectory: planStoreDir, journalStoreDirectory: journalStoreDir)
        
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        
        let bundleURL = rootURL.appendingPathComponent("Applications/Pinned.app")
        try FileManager.default.createDirectory(at: bundleURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plistString = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.pinned</string>
            <key>CFBundleName</key>
            <string>Pinned</string>
        </dict>
        </plist>
        """
        try plistString.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let pinnedFile = bundleURL.appendingPathComponent("Contents/data.bin")
        try Data(repeating: 0, count: 1024).write(to: pinnedFile)
        
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: bundleURL.path)
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let intent = PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: "com.pinned", name: "Pinned"))
        let manualPlan = try await service.plan(intent: intent)
        
        // Pinned - we make it immutable AFTER planning so it gets in the plan, but fails to apply/verify
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: bundleURL.path)
        
        
        let hash = try manualPlan.contentHash()
        let token = await service.tokenStore.mintToken(planId: manualPlan.planId, planHash: hash, requesterIdentity: intent.requesterIdentity)
        
        // Under T-2.4, apply re-validates the plan. Since it's now immutable, 
        // the safety engine drops it from the footprint, causing a step count mismatch during re-validation.
        // Therefore, apply should throw validationFailed and never execute.
        do {
            try await service.apply(planId: manualPlan.planId, token: token)
            XCTFail("Apply should have thrown validationFailed because the target became immutable and was dropped by SafetyEngine")
        } catch BrimService.ApplyError.validationFailed {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
