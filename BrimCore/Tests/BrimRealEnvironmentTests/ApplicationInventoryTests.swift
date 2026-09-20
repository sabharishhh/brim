import XCTest
import BrimCore
@testable import BrimScan

/// The Applications list is the entry point to the deep uninstall, so the
/// identity it shows must be the identity a plan will be built from. These
/// run against the real machine's installed apps.
final class ApplicationInventoryTests: XCTestCase {

    override func setUpWithError() throws {
        try RealEnvironmentFixture.requireEnabled(self)
    }

    private func inventory() -> ApplicationInventory {
        ApplicationInventory(root: FileSystemRoot(rootURL: URL(fileURLWithPath: "/")))
    }

    func testFindsRealApplicationsWithResolvedIdentities() async throws {
        let apps = await inventory().installedApplications()

        XCTAssertFalse(apps.isEmpty, "No applications found on a real machine")

        // Safari ships on every Mac and lives in the protected system domain.
        let safari = apps.first { $0.name == "Safari" }
        XCTAssertNotNil(safari, "Safari should be listed")
        XCTAssertEqual(safari?.identity.bundleID, "com.apple.Safari",
                       "The listed identity must be the resolved bundle identity, not a guess from the file name")
        XCTAssertTrue(safari?.isSystemProtected ?? false,
                      "Apps under /System must be marked protected rather than offered for removal")
        XCTAssertGreaterThan(safari?.bundleSizeBytes ?? 0, 0)
    }

    func testEveryListedApplicationCarriesSomethingToPlanAgainst() async throws {
        let apps = await inventory().installedApplications()

        // A row with no bundle identifier and no name cannot be uninstalled,
        // so it must never reach the list.
        let unplannable = apps.filter { $0.identity.bundleID == nil && $0.identity.name.isEmpty }
        XCTAssertTrue(unplannable.isEmpty, "\(unplannable.count) apps have nothing to plan against")
    }

    func testTheListHasNoDuplicates() async throws {
        let apps = await inventory().installedApplications()
        let paths = apps.map(\.url.standardizedFileURL.path)
        XCTAssertEqual(Set(paths).count, paths.count, "The same bundle was listed twice")
    }

    func testUtilitiesAreFoundOneLevelDown() async throws {
        let apps = await inventory().installedApplications()
        // /System/Applications/Utilities/Terminal.app — nested, and expected.
        XCTAssertTrue(
            apps.contains { $0.name == "Terminal" },
            "Applications inside Utilities should be listed"
        )
    }
}
