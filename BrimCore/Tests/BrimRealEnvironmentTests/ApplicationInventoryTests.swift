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
        // /System/Applications/Utilities/Terminal.app, nested, and expected.
        XCTAssertTrue(
            apps.contains { $0.name == "Terminal" },
            "Applications inside Utilities should be listed"
        )
    }
}

/// Apps shipped inside another app are listed, and stand where their host
/// stands: removable when it is, by removing it.
///
/// Icon Composer, Instruments and FileMerge live in Xcode's
/// `Contents/Applications`. The inventory listed top-level bundles only, so
/// none of them appeared in Apps and searching for them found nothing.
final class EmbeddedApplicationTests: XCTestCase {
    func testAnAppInContentsApplicationsBelongsToItsHost() {
        let url = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/Icon Composer.app")
        XCTAssertEqual(ApplicationInventory.placement(of: url), .some("Xcode"))
    }

    func testAHelperBuriedElsewhereInABundleIsNotAnApp() {
        let url = URL(fileURLWithPath: "/Applications/Chrome.app/Contents/Frameworks/Helper.app")
        XCTAssertTrue(ApplicationInventory.placement(of: url) == nil)
    }

    func testAnAppDeepInOrdinaryFoldersStandsAlone() {
        let url = URL(fileURLWithPath: "/Applications/Adobe/Tools/Bridge.app")
        XCTAssertEqual(ApplicationInventory.placement(of: url), .some(nil))
    }

    func testXcodesToolsAreListedWithTheirHost() async throws {
        try RealEnvironmentFixture.requireEnabled(self)
        let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
        let embedded = ApplicationInventory.embeddedApplications(in: xcode)
        try XCTSkipIf(embedded.isEmpty, "No Xcode with embedded apps on this Mac")
        let apps = await ApplicationInventory(root: FileSystemRoot(rootURL: URL(fileURLWithPath: "/")))
            .installedApplications()
        for url in embedded {
            let listed = apps.first { $0.url.path == url.path }
            XCTAssertNotNil(listed, "\(url.lastPathComponent) is missing from Apps")
            XCTAssertEqual(listed?.enclosingApp, "Xcode")
            // Xcode is the person's own, so what it carries is too.
            XCTAssertFalse(listed?.isSystemProtected ?? true)
            XCTAssertEqual(listed?.hostURL?.path, xcode.path)
        }
    }
}
