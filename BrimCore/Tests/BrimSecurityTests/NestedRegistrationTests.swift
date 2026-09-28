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
}
