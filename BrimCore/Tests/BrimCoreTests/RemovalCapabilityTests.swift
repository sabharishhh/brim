import XCTest
import BrimCore

/// Whether Brim can take a path away, asked before it promises to.
///
/// The incident: two Google Keystone job files in `/Library/LaunchAgents`
/// were offered for removal, authorized with a fingerprint, and then
/// reported as "2 targets still remain" with no reason. Both sat in a
/// directory owned by root. Nothing had asked whether the removal could
/// succeed, and nothing said why it had not.
final class RemovalCapabilityTests: XCTestCase {

    func testRemovingAsksTheDirectoryAndNotTheFile() throws {
        // The rule that was backwards. Unlinking edits the directory, so
        // the directory decides. A read-only file in a writable directory
        // removes perfectly well.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let readOnly = directory.appendingPathComponent("locked.plist")
        try Data().write(to: readOnly)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)

        XCTAssertEqual(RemovalCapability.forDeleting(readOnly.path), .ok,
                       "The file refuses writes, but its directory allows the removal")
    }

    func testARootOwnedDirectoryNeedsAnAdministrator() throws {
        // The real case. /Library/LaunchAgents is root:wheel 755, so a job
        // file there cannot be removed by the person using the Mac.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/Library/LaunchAgents"))
        try XCTSkipIf(getuid() == 0, "Running as root would make this pass for the wrong reason")

        let inSystemFolder = "/Library/LaunchAgents/anything.plist"
        XCTAssertEqual(RemovalCapability.forDeleting(inSystemFolder), .needsHelper)
    }

    func testSomethingInYourOwnLibraryIsFine() {
        let mine = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/anything.plist")
        XCTAssertEqual(RemovalCapability.forDeleting(mine.path), .ok)
    }

    func testEveryRefusalSaysWhyAndSuccessSaysNothing() {
        XCTAssertNil(RemovalCapability.explanation(.ok))
        for blocked: Capability in [.needsHelper, .needsFullDiskAccess, .refusedByOS] {
            let why = RemovalCapability.explanation(blocked)
            XCTAssertNotNil(why, "\(blocked) must explain itself")
            XCTAssertFalse(why?.isEmpty ?? true)
        }
    }
}
