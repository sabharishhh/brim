import XCTest
@testable import BrimCore
@testable import BrimScan

/// Brim asks whether a removal can succeed before offering one: a broken
/// command in root-owned `/usr/local/bin` cannot be removed by the person,
/// so it must say so up front rather than fail after approval.
/// `RefusalCopyTests` holds the wording.
final class OfferedBeforeAskedTests: XCTestCase {

    func testABrokenCommandInARootOwnedFolderIsNotOfferedAsRemovable() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/usr/local/bin"))
        try XCTSkipIf(getuid() == 0, "As root this would pass for the wrong reason")
        try XCTSkipIf(
            access("/usr/local/bin", W_OK) == 0,
            "This Mac's /usr/local/bin is writable, so there is no refusal to catch"
        )

        let leftover = LeftoversScanner.brokenLink(
            URL(fileURLWithPath: "/usr/local/bin/zed"),
            pointingAt: URL(fileURLWithPath: "/Applications/Zed.app/Contents/MacOS/cli")
        )

        XCTAssertEqual(
            leftover.capability, .needsHelper,
            "Offering this leads to a fingerprint and then a refusal, which is the whole "
            + "failure RemovalCapability exists to prevent"
        )
    }

    func testABrokenCommandInAFolderYouOwnStillIs() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offered-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let link = directory.appendingPathComponent("tool")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: "/nowhere/at/all"
        )

        XCTAssertEqual(
            LeftoversScanner.brokenLink(link, pointingAt: URL(fileURLWithPath: "/nowhere/at/all"))
                .capability,
            .ok
        )
    }

    /// The restricted flag is checked on the link itself, since `stat` follows
    /// it to nothing.
    func testTheRestrictedCheckLooksAtTheLinkAndNotItsTarget() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restricted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let link = directory.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: directory.appendingPathComponent("gone").path
        )
        XCTAssertEqual(RemovalCapability.forDeleting(link.path), .ok)
    }
}
