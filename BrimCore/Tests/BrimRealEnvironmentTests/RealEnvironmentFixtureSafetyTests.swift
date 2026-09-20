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
    }
}
