import XCTest
import Foundation
@testable import BrimCore

final class ResetFilterTests: XCTestCase {
    func testEvidenceBasedPreservationInReset() {
        let bundleURL = URL(fileURLWithPath: "/Applications/SuperApp.app")
        let launchdURL = URL(fileURLWithPath: "/Users/alice/Library/LaunchAgents/com.super.helper.plist")
        let receiptURL = URL(fileURLWithPath: "/var/db/receipts/com.super.bom")
        let groupURL = URL(fileURLWithPath: "/Users/alice/Library/Group Containers/TEAM123.com.super.group")
        let licenseURL = URL(fileURLWithPath: "/Users/alice/Library/Application Support/SuperApp/license.lic")
        let keychainURL = URL(fileURLWithPath: "/Users/alice/Library/Keychains/superapp.keychain-db")
        
        let hotkeyCacheURL = URL(fileURLWithPath: "/Users/alice/Library/Caches/SuperApp/hotkeys.json")
        let keyboardPlistURL = URL(fileURLWithPath: "/Users/alice/Library/Preferences/com.super.keyboard.plist")
        let logURL = URL(fileURLWithPath: "/Users/alice/Library/Logs/SuperApp/app.log")
        
        let items: [FootprintItem] = [
            FootprintItem(evidence: Evidence(url: bundleURL, tier: .A, mechanism: "AppBundleSource", humanSentence: ""), sizeBytes: 100, capability: .ok),
            FootprintItem(evidence: Evidence(url: launchdURL, tier: .A, mechanism: "LaunchdSource", humanSentence: ""), sizeBytes: 100, capability: .ok),
            FootprintItem(evidence: Evidence(url: receiptURL, tier: .A, mechanism: "InstallerReceiptSource", humanSentence: ""), sizeBytes: 100, capability: .ok),
            FootprintItem(evidence: Evidence(url: groupURL, tier: .A, mechanism: "GroupContainerSource", humanSentence: ""), sizeBytes: 100, capability: .ok),
            FootprintItem(evidence: Evidence(url: licenseURL, tier: .A, mechanism: "HeuristicSource", humanSentence: ""), sizeBytes: 100, capability: .ok),
            FootprintItem(evidence: Evidence(url: keychainURL, tier: .A, mechanism: "HeuristicSource", humanSentence: ""), sizeBytes: 100, capability: .ok),
            
            // Mutable items that contain substring "key" but should be deleted on reset
            FootprintItem(evidence: Evidence(url: hotkeyCacheURL, tier: .A, mechanism: "HeuristicSource", humanSentence: ""), sizeBytes: 100, capability: .ok),
            FootprintItem(evidence: Evidence(url: keyboardPlistURL, tier: .A, mechanism: "BundleIdentifierComponentSource", humanSentence: ""), sizeBytes: 100, capability: .ok),
            FootprintItem(evidence: Evidence(url: logURL, tier: .A, mechanism: "HeuristicSource", humanSentence: ""), sizeBytes: 100, capability: .ok),
        ]
        
        let footprint = Footprint(identity: Identity(bundleID: "com.super", name: "SuperApp"), items: items)
        let (toDelete, excluded) = ResetFilter.filter(footprint: footprint)
        
        let excludedPaths = excluded.map { $0.target }
        let deletePaths = toDelete.map { $0.evidence.url.path }
        
        // Bundles, launchd, receipts, group containers, licenses, keychains must be excluded from deletion
        XCTAssertTrue(excludedPaths.contains(bundleURL.path))
        XCTAssertTrue(excludedPaths.contains(launchdURL.path))
        XCTAssertTrue(excludedPaths.contains(receiptURL.path))
        XCTAssertTrue(excludedPaths.contains(groupURL.path))
        XCTAssertTrue(excludedPaths.contains(licenseURL.path))
        XCTAssertTrue(excludedPaths.contains(keychainURL.path))
        
        // Hotkey cache and keyboard preferences should NOT be preserved merely because they have "key" in the name
        XCTAssertTrue(deletePaths.contains(hotkeyCacheURL.path), "hotkeys.json should be queued for deletion")
        XCTAssertTrue(deletePaths.contains(keyboardPlistURL.path), "keyboard plist should be queued for deletion")
        XCTAssertTrue(deletePaths.contains(logURL.path), "app.log should be queued for deletion")
    }
}
