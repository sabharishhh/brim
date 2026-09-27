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

    private func smart(_ apps: [InstalledApplication]) -> [String: [String]] {
        let groups = AppGrouper(now: now).groups(apps, by: .smart)
        XCTAssertEqual(groups.flatMap(\.items).count, apps.count, "Every app in exactly one group")
        return Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.items.map(\.name)) })
    }

    func testApplesOwnAppsAreNeverOfferedAsUnusedAndComeLast() {
        let chess = app("Chess", bundleID: "com.apple.Chess", source: .apple, lastOpened: daysAgo(900))
        let old = app("OldTool", lastOpened: daysAgo(200))
        let groups = AppGrouper(now: now).groups([chess, old], by: .smart)
        XCTAssertEqual(groups.map(\.id), ["unused", "apple"])
        XCTAssertTrue(groups.last?.startsCollapsed ?? false)
    }

    func testNoSpotlightRecordIsNotUnused() {
        // "Did not look" is not "nothing found": with Spotlight off there
        // is no date at all, and calling the app unused would be invented.
        let groups = smart([app("Unindexed")])
        XCTAssertEqual(groups["rest"], ["Unindexed"])
        XCTAssertNil(groups["unused"])
    }

    func testMigratedAndNeverOpenedHereIsUnused() {
        // IINA on this Mac: arrived 14 September, last opened 7 August.
        let groups = smart([app("IINA", lastOpened: daysAgo(40), addedAt: daysAgo(20))])
        XCTAssertEqual(groups["unused"], ["IINA"])
    }

    func testASuiteNeedsTwoAppsTheEarlierRulesLeft() {
        let apps = [
            app("Photoshop", team: "ADOBE", developer: "Adobe Inc.", lastOpened: daysAgo(10)),
            app("Illustrator", team: "ADOBE", developer: "Adobe Inc.", lastOpened: daysAgo(12)),
            app("Acrobat", team: "ADOBE", developer: "Adobe Inc.", lastOpened: daysAgo(300)),
            app("Word", team: "MSFT", developer: "Microsoft", lastOpened: daysAgo(10)),
            app("Teams", team: "MSFT", developer: "Microsoft", lastOpened: daysAgo(400))
        ]
        let groups = AppGrouper(now: now).groups(apps, by: .smart)
        let suites = groups.first { $0.id == "suites" }
        XCTAssertEqual(suites?.items.map(\.name), ["Illustrator", "Photoshop"])
        XCTAssertEqual(suites?.subgroups.map(\.title), ["Adobe Inc."])
        XCTAssertEqual(groups.first { $0.id == "unused" }?.items.map(\.name), ["Teams", "Acrobat"], "Oldest first")
        XCTAssertEqual(groups.first { $0.id == "rest" }?.items.map(\.name), ["Word"], "A suite of one is not one")
    }

    func testRecentlyInstalledComesFirst() {
        let groups = AppGrouper(now: now).groups(
            [app("Zed", installedAt: daysAgo(2)), app("Old", lastOpened: daysAgo(3))], by: .smart
        )
        XCTAssertEqual(groups.map(\.id), ["recent", "everyday"])
    }

    func testOnlyFourGroupsStartOpen() {
        let apps = [
            app("New", installedAt: daysAgo(1)), app("Unused", lastOpened: daysAgo(200)),
            app("Huge", size: 5_000_000_000, lastOpened: daysAgo(20)), app("Daily", lastOpened: daysAgo(1)),
            app("Other", lastOpened: daysAgo(20))
        ]
        let groups = AppGrouper(now: now).groups(apps, by: .smart)
        XCTAssertEqual(groups.map(\.id), ["recent", "unused", "large", "everyday", "rest"])
        XCTAssertEqual(groups.map(\.startsCollapsed), [false, false, false, false, true])
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
