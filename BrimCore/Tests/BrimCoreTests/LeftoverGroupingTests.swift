@testable import BrimCore
import XCTest

/// Grouping by software, and what a location means, so the same software is
/// one row and a rebuilt cache is told apart from an app's licence.
final class LeftoverGroupingTests: XCTestCase {
    private func leftover(
        _ path: String,
        owner: Identity? = nil,
        size: Int64 = 1000,
        category: Leftover.Category = .unclaimed,
        capability: Capability = .ok
    ) -> Leftover {
        Leftover(
            url: URL(fileURLWithPath: path), size: size, category: category,
            potentialOwner: owner, evidence: "because", capability: capability
        )
    }

    private let home = "/Users/someone/Library"

    func testDistinctRecordedOwnersWithTheSameNameRemainSeparate() {
        let groups = [
            leftover("\(home)/Caches/org.example.editor", owner: Identity(
                bundleID: "org.example.editor", name: "Editor"
            ), category: .orphaned),
            leftover("\(home)/Caches/net.other.editor", owner: Identity(
                bundleID: "net.other.editor", name: "Editor"
            ), category: .orphaned),
            leftover("\(home)/Caches/org.example.editor.beta", owner: Identity(
                bundleID: "org.example.editor.beta", name: "Editor Beta"
            ), category: .orphaned)
        ].groupedByOwner()
        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups.allSatisfy { $0.items.count == 1 })
    }

    func testVersionedFileNamesAreNotApplicationNamespaces() {
        XCTAssertNil(OwnerNamespace.key(for: "Adobe Save for Web 13.0 Prefs"))
        XCTAssertNil(OwnerNamespace.key(for: "settings.2.backup"))
        XCTAssertEqual(OwnerNamespace.key(for: "com.example.editor.helper.plist"), "com.example.editor")
    }

    // MARK: - Grouping

    func testTheSameToolInTwoPlacesIsOneEntry() {
        // `Codex` in Application Support and in Caches is one product.
        let groups = [
            leftover("\(home)/Application Support/Codex", size: 147),
            leftover("\(home)/Caches/Codex", size: 119)
        ].groupedByOwner()

        XCTAssertEqual(groups.count, 1, "One piece of software, one entry")
        XCTAssertEqual(groups[0].displayName, "Codex")
        XCTAssertEqual(groups[0].items.count, 2)
        XCTAssertEqual(groups[0].totalBytes, 266)
    }

    func testABundleIdentifierGroupsAcrossDifferingFileNames() {
        let identity = Identity(bundleID: "com.acme.tool", name: "Acme Tool")
        let groups = [
            leftover("\(home)/Caches/com.acme.tool", owner: identity),
            leftover("\(home)/Preferences/com.acme.tool.plist", owner: identity),
            leftover("\(home)/Saved Application State/com.acme.tool.savedState", owner: identity)
        ].groupedByOwner()

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].identifier, "com.acme.tool")
        XCTAssertEqual(groups[0].displayName, "Acme Tool", "The human name, not the identifier")
    }

    /// Several broken links into one removed app, each with its own name and no
    /// identifier, group under the resolved owner, as one row with its own id.
    func testSeveralUnidentifiedItemsSharingAResolvedOwnerNameMergeIntoOneGroup() {
        let owner = Identity(bundleID: nil, name: "Docker.app")
        let leftovers = [
            leftover("/usr/local/bin/docker", owner: owner, category: .orphaned),
            leftover("/usr/local/bin/kubectl", owner: owner, category: .orphaned),
            leftover("/usr/local/bin/cagent", owner: owner, category: .orphaned),
            leftover("/usr/local/bin/docker-compose", owner: owner, category: .orphaned)
        ]
        let groups = leftovers.groupedByOwner()

        XCTAssertEqual(groups.count, 1, "One departed application, one row")
        XCTAssertEqual(groups[0].items.count, 4)
        XCTAssertEqual(groups[0].displayName, "Docker.app")
    }

    /// `id` is the bucket key, unique by construction, so two groups cannot
    /// collide on a display name.
    func testGroupIdenityNeverCollidesAcrossDistinctOwners() {
        let groups = [
            leftover("\(home)/Caches/Codex"),
            leftover("\(home)/Caches/Loki"),
            leftover(
                "/usr/local/bin/pythont",
                owner: Identity(bundleID: nil, name: "PythonT.framework"), category: .orphaned
            )
        ].groupedByOwner()

        XCTAssertEqual(groups.count, 3)
        let ids = Set(groups.map(\.id))
        XCTAssertEqual(ids.count, 3, "Every distinct group must have a distinct id")
    }

    /// One product that resolves unevenly (one item with identifier and name,
    /// another with only the name) is still one row.
    func testOneProductThatResolvesUnevenlyIsStillOneRow() {
        let withIdentifier = Identity(bundleID: "dev.warp.Warp", name: "Warp")
        let nameOnly = Identity(bundleID: nil, name: "Warp")

        let groups = [
            leftover("\(home)/Group Containers/2BBY89MBSN.dev.warp", owner: withIdentifier),
            leftover("\(home)/Application Scripts/2BBY89MBSN.dev.warp", owner: nameOnly)
        ].groupedByOwner()

        XCTAssertEqual(groups.count, 1, "One product, however unevenly it resolved")
        XCTAssertEqual(groups[0].items.count, 2)
        XCTAssertEqual(groups[0].displayName, "Warp")
        XCTAssertEqual(groups[0].identifier, "dev.warp.Warp", "The stronger name survives the merge")
    }

    func testJoiningOwnerNamesDoesNotChainUnrelatedSoftwareTogether() {
        // The join is transitive, so a name only links what actually carries it.
        let groups = [
            leftover("\(home)/Caches/A", owner: Identity(bundleID: "com.a.app", name: "Alpha")),
            leftover("\(home)/Caches/B", owner: Identity(bundleID: "com.b.app", name: "Beta")),
            leftover("\(home)/Caches/C", owner: Identity(bundleID: nil, name: "Beta"))
        ].groupedByOwner()

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.displayName)), ["Alpha", "Beta"])
        XCTAssertEqual(groups.first { $0.displayName == "Beta" }?.items.count, 2)
    }

    func testDifferentSoftwareStaysApart() {
        let groups = [
            leftover("\(home)/Caches/Codex"),
            leftover("\(home)/Caches/Loki")
        ].groupedByOwner()
        XCTAssertEqual(groups.count, 2)
    }

    func testReverseDNSHelpersStayWithTheirProductWithoutMergingVendorApps() {
        let groups = [
            leftover("\(home)/Containers/com.microsoft.teams2.agent"),
            leftover("\(home)/Preferences/com.microsoft.teams2.notificationcenter.plist"),
            leftover("\(home)/Preferences/com.microsoft.office.plist"),
            leftover("\(home)/HTTPStorages/com.openai.chat.binarycookies"),
            leftover("\(home)/WebKit/com.openai.chat")
        ].groupedByOwner()

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.first { $0.groupKey == "com.microsoft.teams2" }?.items.count, 2)
        XCTAssertEqual(groups.first { $0.groupKey == "com.openai.chat" }?.items.count, 2)
        XCTAssertEqual(groups.first { $0.groupKey == "com.microsoft.office" }?.items.count, 1)
    }

    func testGroupsAreOrderedByWhatTheyCost() {
        let groups = [
            leftover("\(home)/Caches/Small", size: 10),
            leftover("\(home)/Caches/Large", size: 900)
        ].groupedByOwner()
        XCTAssertEqual(groups.map(\.displayName), ["Large", "Small"])
    }

    func testAGroupIsOrphanedIfAnyPartOfItIs() {
        // The evidence naming a departed owner is about the software, so it
        // applies to everything that software left.
        let group = [
            leftover("\(home)/Caches/Tool", category: .unclaimed),
            leftover("\(home)/Application Support/Tool", category: .orphaned)
        ].groupedByOwner()[0]

        XCTAssertEqual(group.category, .orphaned)
    }

    func testAGroupIsNotActionableWhenAnyPartIsBlocked() {
        // A partly removable group must not look removable.
        let group = [
            leftover("\(home)/Caches/Tool"),
            leftover("\(home)/Containers/Tool", capability: .needsFullDiskAccess)
        ].groupedByOwner()[0]

        XCTAssertFalse(group.isFullyActionable)
    }

    // MARK: - What a location means

    func testTheDomainIsReadFromWhereTheItemLives() {
        XCTAssertEqual(LeftoverDomain.of(URL(fileURLWithPath: "\(home)/Caches/x")), .cache)
        XCTAssertEqual(LeftoverDomain.of(URL(fileURLWithPath: "\(home)/Application Support/x")), .applicationSupport)
        XCTAssertEqual(LeftoverDomain.of(URL(fileURLWithPath: "\(home)/Preferences/x.plist")), .preferences)
        XCTAssertEqual(LeftoverDomain.of(URL(fileURLWithPath: "\(home)/Logs/x")), .logs)
        XCTAssertEqual(LeftoverDomain.of(URL(fileURLWithPath: "\(home)/HTTPStorages/x")), .webData)
        XCTAssertEqual(LeftoverDomain.of(URL(fileURLWithPath: "\(home)/WebKit/x")), .webData)
        XCTAssertEqual(LeftoverDomain.of(URL(fileURLWithPath: "\(home)/Group Containers/x")), .groupContainer)
        XCTAssertEqual(LeftoverDomain.of(URL(fileURLWithPath: "\(home)/Containers/x")), .container)
        XCTAssertEqual(LeftoverDomain.of(URL(fileURLWithPath: "/tmp/x")), .other)
    }

    /// The Darwin per-user folders are recognised, not called "an unrecognised
    /// location".
    func testTheDarwinPerUserFoldersAreRecognisedAndNotCalledUnrecognised() {
        let cache = URL(fileURLWithPath:
            "/private/var/folders/s9/_zb8zd8j2yzd8kx5xfqbyyj80000gn/C/net.freemacsoft.AppCleaner")
        let temp = URL(fileURLWithPath:
            "/var/folders/s9/_zb8zd8j2yzd8kx5xfqbyyj80000gn/T/com.example.tool")

        XCTAssertEqual(LeftoverDomain.of(cache), .darwinPerUser)
        XCTAssertEqual(LeftoverDomain.of(temp), .darwinPerUser)
        XCTAssertFalse(LeftoverDomain.darwinPerUser.whatItHolds.contains("unrecognised"))

        // The fixture root's stand-ins answer the same way as the real folders.
        XCTAssertEqual(
            LeftoverDomain.of(URL(fileURLWithPath: "/tmp/root/private/var/folders/DarwinUserCache/x")),
            .darwinPerUser
        )
    }

    func testSomethingGenuinelyElsewhereIsStillOther() {
        XCTAssertEqual(LeftoverDomain.of(URL(fileURLWithPath: "/usr/local/bin/tool")), .other)
        // Two components under /var/folders is not the per-user shape.
        XCTAssertEqual(LeftoverDomain.of(URL(fileURLWithPath: "/var/folders/zz/zyxvpxvq6csfxvn_n00000sm")), .other)
    }

    func testGroupContainersAreNotMistakenForContainers() {
        // "Group Containers" contains the word "Containers", and the two
        // mean different things: one may still be in use by other software.
        XCTAssertEqual(
            LeftoverDomain.of(URL(fileURLWithPath: "\(home)/Group Containers/group.com.acme")),
            .groupContainer
        )
    }

    func testWhatComesBackByItselfIsSeparatedFromWhatDoesNot() {
        // What is lost: a group of two where only one holds anything the app would
        // have remembered.
        let group = [
            leftover("\(home)/Caches/Tool", size: 900),
            leftover("\(home)/Application Support/Tool", size: 100)
        ].groupedByOwner()[0]

        XCTAssertEqual(group.regeneratedBytes, 900)
        XCTAssertEqual(group.meaningfulBytes, 100)
    }

    func testEveryDomainSaysWhatItHoldsAndWhetherItReturns() {
        for domain in LeftoverDomain.allCases {
            XCTAssertFalse(domain.title.isEmpty, "\(domain) has no title")
            XCTAssertFalse(domain.whatItHolds.isEmpty, "\(domain) explains nothing")
            XCTAssertFalse(domain.consequence.isEmpty, "\(domain) states no consequence")
        }
        XCTAssertTrue(LeftoverDomain.cache.isRegenerated)
        XCTAssertFalse(LeftoverDomain.applicationSupport.isRegenerated,
                       "App data is the one a user must be warned about")
    }

    func testTheMeaningfulLocationsAreListedFirst() {
        let group = [
            leftover("\(home)/Caches/Tool"),
            leftover("\(home)/Application Support/Tool")
        ].groupedByOwner()[0]

        XCTAssertEqual(group.domains.first, .applicationSupport,
                       "What the user stands to lose leads, not the cache")
    }
}
