import XCTest
@testable import BrimCore
@testable import BrimScan

/// Brim asks whether a removal can succeed before it offers one.
///
/// The incident, the second time. Fourteen broken commands in
/// `/usr/local/bin` were found by the sweep, listed, grouped, ticked by
/// default, planned, authorized with a fingerprint and then refused by the
/// kernel. `/usr/local/bin` is `root:wheel` and `drwxr-xr-x`, and unlinking
/// a name edits the directory holding it, so nothing the person runs can
/// remove anything there.
///
/// `RemovalCapability` has known this since two Google Keystone jobs in
/// `/Library/LaunchAgents` produced exactly the same sequence. The sweep
/// never called it: `brokenLink` wrote `capability: .ok` as a literal, and
/// the general case ended in `default: return .ok`. So one module knew and
/// another assumed, which is this codebase's recurring defect.
///
/// The message that came back afterwards is held by `RefusalCopyTests`,
/// which lives with the service that writes it.
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

    /// A broken link could not be checked for the restricted flag at all,
    /// because `stat` follows the link and there is nothing at the far end.
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
