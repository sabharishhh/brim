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
        let caches = folder.appendingPathComponent("Caches")
        XCTAssertEqual(LaunchServicesRegistration.nestedApplications(in: caches.path), [cached.path])
        let absent = folder.appendingPathComponent("none")
        XCTAssertEqual(LaunchServicesRegistration.nestedApplications(in: absent.path), [])
    }

    /// Teams' embedded browser had already moved to a newer version folder,
    /// and three helpers in the old one stayed registered through the
    /// uninstall: nothing on disk named them any more.
    func testRecordsInsideARemovedPathThatPointAtNothingAreFound() async throws {
        let dump = """
        path:                       /Applications/Gone.app/Contents/Helpers/Helper (GPU).app (0x653c)
        path:                       /Applications/Gone.app (0x6864)
        path:                       /Applications/GoneToo.app (0x6865)
        path:                       /System/Applications/Notes.app (0x1)
        name:                       Something else
        """
        let records = try await LaunchServicesRegistration.staleRecords(inside: ["/Applications/Gone.app"], dump: dump)
        XCTAssertEqual(
            records,
            ["/Applications/Gone.app/Contents/Helpers/Helper (GPU).app"]
        )
    }
}
