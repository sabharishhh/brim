import BrimCore
@testable import BrimUI
import XCTest

/// Smart groups answer "which of these could go?", so every claim a group
/// makes about an app has to be one Brim can prove.
final class AppGroupingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86400)
    }

    private func app(
        _ name: String, bundleID: String? = nil, team: String? = nil, developer: String? = nil,
        source: ApplicationSource = .direct, size: Int64 = 50_000_000,
        lastOpened: Date? = nil, addedAt: Date? = nil, installedAt: Date? = nil
    ) -> InstalledApplication {
        InstalledApplication(
            identity: Identity(bundleID: bundleID ?? "com.test.\(name)", teamID: team, name: name),
            url: URL(fileURLWithPath: "/Applications/\(name).app"), bundleSizeBytes: size,
            isSystemProtected: false, source: source, developer: developer,
            lastOpened: lastOpened, addedAt: addedAt, installedAt: installedAt
        )
    }

    /// Smart is two groups: what you installed, and what cannot be removed.
    func testSmartSplitsWhatCanGoFromWhatCannot() {
        var chess = app("Chess", bundleID: "com.apple.Chess", source: .apple, lastOpened: daysAgo(1))
        chess = InstalledApplication(
            identity: chess.identity, url: chess.url, bundleSizeBytes: 1, isSystemProtected: true,
            lastOpened: chess.lastOpened
        )
        let xcode = app("Xcode", bundleID: "com.apple.dt.Xcode", source: .appStore, lastOpened: daysAgo(3))
        let groups = AppGrouper(now: now).groups([chess, xcode], by: .smart)

        XCTAssertEqual(groups.map(\.id), ["yours", "builtin"])
        // Xcode is Apple's, and still something you installed and can remove.
        XCTAssertEqual(groups.first?.items.map(\.name), ["Xcode"])
    }

    func testMostRecentlyUsedComeFirstAndUndatedLast() {
        let apps = [
            app("Old", lastOpened: daysAgo(200)), app("Unindexed"), app("Today", lastOpened: daysAgo(0.1))
        ]
        let names = AppGrouper(now: now).groups(apps, by: .smart).first?.items.map(\.name)
        XCTAssertEqual(names, ["Today", "Old", "Unindexed"])
    }
}

/// Names and categories as a person reads them.
final class ApplicationFactsTests: XCTestCase {
    func testDeveloperNamesComeFromTheCertificate() {
        XCTAssertEqual(
            ApplicationFacts.organisation(fromCertificateSummary: "Developer ID Application: Adobe Inc. (JQ525L2MZD)"),
            "Adobe Inc."
        )
        XCTAssertNil(ApplicationFacts.organisation(fromCertificateSummary: "Apple Mac OS Application Signing"))
        XCTAssertNil(ApplicationFacts.organisation(fromCertificateSummary: "Apple Development: me@example.dev (X1)"))
        XCTAssertEqual(ApplicationFacts.categoryTitle("public.app-category.graphics-design"), "Graphics & Design")
        XCTAssertEqual(ApplicationFacts.categoryTitle("public.app-category.puzzle-games"), "Games")
    }
}
