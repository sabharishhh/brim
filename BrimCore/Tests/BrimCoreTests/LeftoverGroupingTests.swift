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
