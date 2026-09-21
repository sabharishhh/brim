import XCTest
@testable import BrimService

/// The rail that keeps a destructive harness from touching anything real.
/// Deliberately not gated behind BRIM_REAL_ENV: it touches no disk, and it is
/// the check that must never silently stop running.
final class RealEnvironmentFixtureSafetyTests: XCTestCase {

    func testTheFixtureRefusesToRemoveAnythingItDidNotCreate() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dangerous = [
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Library/Application Support"),
            home.appendingPathComponent("Library/Caches/com.apple.Safari"),
            URL(fileURLWithPath: "/Applications/Safari.app"),
            URL(fileURLWithPath: "/"),
            // Namespaced, but escaping the namespace via traversal.
            home.appendingPathComponent("Library/Caches/BrimHarness-x/../../../Documents")
        ]

        for url in dangerous {
            XCTAssertFalse(
                RealEnvironmentFixture.isSafeToRemove(url),
                "Harness must refuse \(url.path)"
            )
        }

        let legitimate = home.appendingPathComponent("Library/Caches/BrimHarness-abc123-cache")
        XCTAssertTrue(RealEnvironmentFixture.isSafeToRemove(legitimate))

        // ~/Applications is allowed, because a Launch Services registration
        // can only be proven against a bundle installed where apps go. The
        // marker rule still applies, and /Applications still does not.
        XCTAssertTrue(RealEnvironmentFixture.isSafeToRemove(
            home.appendingPathComponent("Applications/BrimHarness-abc123.app")
        ))
        XCTAssertFalse(RealEnvironmentFixture.isSafeToRemove(
            URL(fileURLWithPath: "/Applications/BrimHarness-abc123.app")
        ), "System-wide /Applications is never the harness's to touch")
        XCTAssertFalse(RealEnvironmentFixture.isSafeToRemove(
            home.appendingPathComponent("Applications/Something.app")
        ), "Unmarked bundles stay off limits even in an allowed root")
    }
}
