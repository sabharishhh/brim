import XCTest
import Foundation
@testable import BrimCore
@testable import BrimScan

final class LeftoversScannerTests: XCTestCase {
    func testActiveAppGroupContainersAndAppSupportNotMarkedAsLeftovers() async throws {
        let rawTempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: rawTempDir, withIntermediateDirectories: true)
        let tempDir = rawTempDir.resolvingSymlinksInPath()
        let root = FileSystemRoot(rootURL: tempDir, userName: "testuser")
        
        let appURL = root.url(for: .applications).appendingPathComponent("TestApp.app")
        try fm.createDirectory(at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        
        let infoPlistData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.TestApp",
                "CFBundleName": "TestApp"
            ],
            format: .xml,
            options: 0
        )
        try infoPlistData.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        
        // Active group container with team ID prefix
        let groupContainerURL = root.url(for: .userGroupContainers).appendingPathComponent("TEAM12345.com.example.TestApp")
        try fm.createDirectory(at: groupContainerURL, withIntermediateDirectories: true)
        try "group data".write(to: groupContainerURL.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        
        // Active Application Support using app name rather than bundle ID
        let appSupportURL = root.url(for: .userApplicationSupport).appendingPathComponent("TestApp")
        try fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        try "app support data".write(to: appSupportURL.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        
        // Orphaned app support directory (with installer receipt)
        let receiptsDir = tempDir.appendingPathComponent("var/db/receipts")
        try fm.createDirectory(at: receiptsDir, withIntermediateDirectories: true)
        try "receipt".write(to: receiptsDir.appendingPathComponent("com.old.orphaned.plist"), atomically: true, encoding: .utf8)
        let orphanedURL = root.url(for: .userApplicationSupport).appendingPathComponent("com.old.orphaned")
        try fm.createDirectory(at: orphanedURL, withIntermediateDirectories: true)
        
        // Truly unclaimed directory. With something in it: an empty
        // folder nobody can name gives back nothing and is left out, so a
        // fixture that tests attribution has to hold some bytes or it is
        // testing the noise filter instead.
        let unclaimedURL = root.url(for: .userApplicationSupport).appendingPathComponent("MysteryTool")
        try fm.createDirectory(at: unclaimedURL, withIntermediateDirectories: true)
        try "mystery".write(
            to: unclaimedURL.appendingPathComponent("data.bin"),
            atomically: true, encoding: .utf8
        )
        
        let scanner = LeftoversScanner(root: root)
        let leftovers = try await scanner.scanLeftovers()
        // 1. Active group container must NOT be in leftovers
        let leftoverNames = leftovers.map { $0.url.lastPathComponent }
        XCTAssertFalse(leftoverNames.contains(groupContainerURL.lastPathComponent), "Active group container should not be identified as leftover")
        
        // 2. Active application support must NOT be in leftovers
        XCTAssertFalse(leftoverNames.contains(appSupportURL.lastPathComponent), "Active application support directory should not be identified as leftover")
        
        // 3. Orphaned app support must be identified as .orphaned
        let orphanedMatch = leftovers.first(where: { $0.url.lastPathComponent == orphanedURL.lastPathComponent })
        XCTAssertNotNil(orphanedMatch, "Orphaned item should be detected")
        XCTAssertEqual(orphanedMatch?.category, .orphaned)
        
        // 4. Truly unclaimed item must be identified as .unclaimed
        let unclaimedMatch = leftovers.first(where: { $0.url.lastPathComponent == unclaimedURL.lastPathComponent })
        XCTAssertNotNil(unclaimedMatch, "Unclaimed item should be detected")
        XCTAssertEqual(unclaimedMatch?.category, .unclaimed)
    }
}

/// Apple's own data is never the user's to clean up, and the group-container
/// spelling is the case that slipped through: a container named
/// `group.com.apple.SHTTS` does not begin with `com.apple.`, so it was being
/// offered as a leftover. One had been written to under a minute before the
/// scan that found it.
final class AppleOwnedFilterTests: XCTestCase {

    func testSystemDataIsNeverOfferedInEitherSpelling() {
        XCTAssertTrue(LeftoversScanner.isAppleOwned("com.apple.Safari"))
        XCTAssertTrue(LeftoversScanner.isAppleOwned("group.com.apple.SHTTS"))
        XCTAssertTrue(LeftoversScanner.isAppleOwned("group.com.apple.gamecenter"))
        XCTAssertTrue(LeftoversScanner.isAppleOwned("com.apple"))
    }

    func testSeparatelyShippedAppleSoftwareStaysRemovable() {
        // Logic and Final Cut are bought and uninstalled like anything else,
        // and their support folders are the largest leftovers on many Macs.
        XCTAssertFalse(LeftoversScanner.isAppleOwned("com.apple.logic10"))
        XCTAssertFalse(LeftoversScanner.isAppleOwned("com.apple.FinalCut"))
    }

    func testThirdPartySoftwareIsUnaffected() {
        XCTAssertFalse(LeftoversScanner.isAppleOwned("com.figma.Desktop"))
        XCTAssertFalse(LeftoversScanner.isAppleOwned("group.com.acme.shared"))
        XCTAssertFalse(LeftoversScanner.isAppleOwned("Codex"))
        // Not a prefix match on something merely starting with the letters.
        XCTAssertFalse(LeftoversScanner.isAppleOwned("com.applesauce.jam"))
    }
}
