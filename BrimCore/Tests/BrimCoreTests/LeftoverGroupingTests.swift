import XCTest
@testable import BrimCore

/// Grouping, and what a location means. Both exist because the flat list
/// could not be reasoned about: the same software appeared several times
/// with nothing to connect the rows, and nothing on screen distinguished a
/// cache that rebuilds itself from the folder holding an app's licence.
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

    // MARK: - Grouping

    func testTheSameToolInTwoPlacesIsOneEntry() {
        // The case that prompted this: Codex appeared twice, 147 MB in
        // Application Support and 119 MB in Caches, with nothing saying
        // they were the same thing.
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

    /// Seven broken symlinks left by an uninstalled Docker, each pointing
    /// into `Docker.app`, each its own file with its own name (`docker`,
    /// `kubectl`, `cagent`...), none carrying a bundle identifier. Before
    /// this fix each one bucketed under its own file name into seven
    /// single-item groups, all displaying the resolved owner name
    /// "Docker.app" and all re-deriving the identical `id` from that shared
    /// display name, so SwiftUI's list treated seven distinct rows as one
    /// element: selecting one silently selected all seven, and there was no
    /// way to tell whether they even lived in the same place.
    func testSeveralUnidentifiedItemsSharingAResolvedOwnerNameMergeIntoOneGroup() {
        let owner = Identity(bundleID: nil, name: "Docker.app")
        let leftovers = [
            leftover("/usr/local/bin/docker", owner: owner, category: .orphaned),
            leftover("/usr/local/bin/kubectl", owner: owner, category: .orphaned),
            leftover("/usr/local/bin/cagent", owner: owner, category: .orphaned),
            leftover("/usr/local/bin/docker-compose", owner: owner, category: .orphaned),
        ]
        let groups = leftovers.groupedByOwner()

        XCTAssertEqual(groups.count, 1, "One departed application, one row")
        XCTAssertEqual(groups[0].items.count, 4)
        XCTAssertEqual(groups[0].displayName, "Docker.app")
    }

    /// `id` used to be re-derived from `displayName` after grouping had
    /// already happened, so a future change to how a name is chosen could
    /// silently make two distinct groups collide again. Pinning `id` to the
    /// actual bucket key, unique by construction, holds that shut for good.
    func testGroupIdenityNeverCollidesAcrossDistinctOwners() {
        let groups = [
            leftover("\(home)/Caches/Codex"),
            leftover("\(home)/Caches/Loki"),
            leftover(
                "/usr/local/bin/pythont",
                owner: Identity(bundleID: nil, name: "PythonT.framework"), category: .orphaned
            ),
        ].groupedByOwner()

        XCTAssertEqual(groups.count, 3)
        let ids = Set(groups.map(\.id))
        XCTAssertEqual(ids.count, 3, "Every distinct group must have a distinct id")
    }

    /// Warp appeared as two rows on a real Mac, each saying "1 location",
    /// both called Warp: `Application Scripts/2BBY89MBSN.dev.warp` and
    /// `Group Containers/2BBY89MBSN.dev.warp`. One resolved a bundle
    /// identifier as well as the name and the other resolved only the name,
    /// so the stronger key put them in different buckets. The leftover that
    /// carries both is itself the evidence that the two names are one
    /// product.
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
        // The join is transitive by design, so the guard is that a name only
        // links what actually carries it.
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
        // A group that is partly removable must not look removable, or the
        // user authorises something that half happens.
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

    /// `LocationInventory` has scanned `darwinUserCache` and `darwinUserTemp`
    /// since they were added, and this classifier did not know them, so every
    /// real find there reached the list badged "Other" above the sentence "An
    /// unrecognised location." Seen on this Mac: AppCleaner's 50 KB under
    /// `/private/var/folders/…/C/net.freemacsoft.AppCleaner`. Two places
    /// reading one fact, and only one of them had been told.
    func testTheDarwinPerUserFoldersAreRecognisedAndNotCalledUnrecognised() {
        let cache = URL(fileURLWithPath:
            "/private/var/folders/s9/_zb8zd8j2yzd8kx5xfqbyyj80000gn/C/net.freemacsoft.AppCleaner")
        let temp = URL(fileURLWithPath:
            "/var/folders/s9/_zb8zd8j2yzd8kx5xfqbyyj80000gn/T/com.example.tool")

        XCTAssertEqual(LeftoverDomain.of(cache), .darwinPerUser)
        XCTAssertEqual(LeftoverDomain.of(temp), .darwinPerUser)
        XCTAssertFalse(LeftoverDomain.darwinPerUser.whatItHolds.contains("unrecognised"))

        // The fixture root's stand-ins answer the same way, or a test tree
        // and the real machine disagree about the same folder.
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
        // mean different things — one may still be in use by other software.
        XCTAssertEqual(
            LeftoverDomain.of(URL(fileURLWithPath: "\(home)/Group Containers/group.com.acme")),
            .groupContainer
        )
    }

    func testWhatComesBackByItselfIsSeparatedFromWhatDoesNot() {
        // The number that actually answers "what do I lose": a group of two
        // where only one holds anything the app would have remembered.
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
