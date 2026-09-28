import BrimOps
import XCTest

/// After Muse was removed, Launch Services still listed Sparkle's
/// `Updater.app` inside `Muse.app` and two copies Sparkle kept in its cache
/// folder, all pointing at nothing. Unregistering the application does not
/// reach the applications inside it, so they are found before it goes.
final class NestedRegistrationTests: XCTestCase {
    func testApplicationsInsideSomethingRemovedAreFound() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nested-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let host = folder.appendingPathComponent("Host.app")
        let updater = host.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app")
        let cached = folder.appendingPathComponent("Caches/Launcher/abc/Updater.app")
        for url in [updater, cached] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"),
                                                    withIntermediateDirectories: true)
        }
        XCTAssertEqual(LaunchServicesRegistration.nestedApplications(in: host.path), [updater.path])
        XCTAssertEqual(LaunchServicesRegistration.nestedApplications(in: folder.appendingPathComponent("Caches").path),
                       [cached.path])
        XCTAssertEqual(LaunchServicesRegistration.nestedApplications(in: folder.appendingPathComponent("none").path), [])
    }

    /// Teams' embedded browser had already moved to a newer version folder,
    /// and three helpers in the old one stayed registered through the
    /// uninstall: nothing on disk named them any more.
    func testRecordsInsideARemovedPathThatPointAtNothingAreFound() {
        let dump = """
        path:                       /Applications/Gone.app/Contents/Frameworks/Edge.framework/Versions/1/Helpers/Helper (GPU).app (0x653c)
        path:                       /Applications/Gone.app (0x6864)
        path:                       /Applications/GoneToo.app (0x6865)
        path:                       /System/Applications/Notes.app (0x1)
        name:                       Something else
        """
        XCTAssertEqual(
            LaunchServicesRegistration.staleRecords(inside: ["/Applications/Gone.app"], dump: dump),
            ["/Applications/Gone.app/Contents/Frameworks/Edge.framework/Versions/1/Helpers/Helper (GPU).app"]
        )
    }
}
