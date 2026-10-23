import XCTest
import BrimCore

/// Whether Brim can take a path away, asked before it promises to.
final class RemovalCapabilityTests: XCTestCase {

    func testRemovingAsksTheDirectoryAndNotTheFile() throws {
        // Unlinking edits the folder, so the folder decides: a read-only file in a
        // writable folder is removable.
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
        // `/Library/LaunchAgents` is `root:wheel` 755, so the person cannot remove
        // a job file there.
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

    /// What macOS protects with `SF_NOUNLINK` or `SF_RESTRICTED` is never an
    /// app's to remove. A test cannot set those flags, so it uses `/System`.
    func testWhatMacOSProtectsForItselfIsNeverAnAppsToRemove() throws {
        XCTAssertTrue(RemovalCapability.isProtectedBySystem("/System"))
        let mine = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: mine)
        defer { try? FileManager.default.removeItem(at: mine) }
        XCTAssertFalse(RemovalCapability.isProtectedBySystem(mine.path))
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
