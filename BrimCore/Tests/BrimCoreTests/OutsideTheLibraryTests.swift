import XCTest
import BrimCore
@testable import BrimScan

/// Where cross-platform software actually keeps its data.
///
/// Software written for Linux first looks in `~/.config`, `~/.cache` and
/// `~/.local/share`, because that is where its other builds already look and
/// rewriting it for macOS is work almost nobody does. Nothing in Brim read
/// `$HOME` directly, so the single largest thing any measured application had
/// on this Mac, 189 MB under `~/.local/share/claude`, was invisible to every
/// evidence source at once.
final class OutsideTheLibraryTests: XCTestCase {

    private var rootURL: URL!
    private var root: FileSystemRoot!

    override func setUpWithError() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xdg-\(UUID().uuidString)")
        root = FileSystemRoot(rootURL: rootURL, userName: "tester")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    @discardableResult
    private func make(_ domain: FileSystemRoot.Domain, _ name: String) throws -> URL {
        let directory = root.url(for: domain)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        return item
    }

    /// **The 189 MB.** The folder is lower case and the application is not.
    func testALowercasedFolderOutsideTheLibraryIsFound() throws {
        let data = try make(.userDotLocalShare, "claude")
        let identity = Identity(bundleID: "com.anthropic.claudefordesktop", name: "Claude")

        let found = LocationInventorySource(budget: { .unlimited })
            .findings(for: identity, in: root).evidence

        XCTAssertTrue(
            found.contains { $0.url.standardizedFileURL.path == data.standardizedFileURL.path },
            "~/.local/share/claude is Claude's and was not found."
        )
    }

    /// The rule says lowercased, so it has to actually lowercase rather than
    /// lean on a case-insensitive volume. Most Macs have one and would hide
    /// this; the developers most likely to have a case-sensitive volume are
    /// exactly the people whose `~/.cache` is measured in gigabytes.
    func testTheRuleLowercasesRatherThanTrustingTheVolume() {
        let identity = Identity(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")
        let location = LocationInventory.Location(
            domain: .userDotConfig, rule: .applicationNameLowercased,
            describes: "settings", sentence: "."
        )
        XCTAssertEqual(
            LocationInventorySource.candidates(for: location, identity: identity),
            ["visual studio code"],
            "The candidate is not lowercased, so this only ever worked by accident."
        )
    }

    /// Both names, lowercased, without duplicates when they agree.
    func testBothNamesAreLoweredAndDeduplicated() {
        let location = LocationInventory.Location(
            domain: .userDotConfig, rule: .applicationNameLowercased,
            describes: "settings", sentence: "."
        )
        let twoNames = Identity(
            bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", bundleName: "Code"
        )
        XCTAssertEqual(
            LocationInventorySource.candidates(for: location, identity: twoNames),
            ["visual studio code", "code"]
        )
        let oneName = Identity(bundleID: "md.obsidian", name: "Obsidian", bundleName: "Obsidian")
        XCTAssertEqual(
            LocationInventorySource.candidates(for: location, identity: oneName),
            ["obsidian"]
        )
    }

    /// Nothing here carries a bundle identifier, so nothing here is ever
    /// more than a name match, and the domain floors the tier whatever a row
    /// might claim.
    func testEverythingOutsideTheLibraryIsTierC() {
        let outside: [FileSystemRoot.Domain] = [
            .userDotConfig, .userDotCache, .userDotLocalShare,
            .userDotLocalState, .userDotLocalBin,
        ]
        for domain in outside {
            let optimistic = LocationInventory.Location(
                domain: domain, rule: .bundleIdentifier, describes: "x", sentence: "x"
            )
            XCTAssertEqual(
                optimistic.tier, .C,
                "\(domain) can only ever be name-matched and a row claimed otherwise."
            )
        }
        let covered = Set(LocationInventory.standard.locations.map(\.domain))
        for domain in outside {
            XCTAssertTrue(covered.contains(domain), "\(domain) is still not looked at")
        }
    }

    /// **The sweep must not widen by accident.** `sweepDomains` is derived
    /// from the same table, minus an exclusion list, so adding a location is
    /// enough to put it in the leftovers list without anybody deciding to.
    /// These folders belong overwhelmingly to command line tools that are
    /// still installed, and a tool has no bundle for the sweep's ownership
    /// test to find, so every one of them would be offered as a leftover.
    func testTheLeftoversSweepDidNotQuietlyGainTheseFolders() {
        let swept = Set(LocationInventory.sweepDomains)
        for domain in [FileSystemRoot.Domain.userDotConfig, .userDotCache,
                       .userDotLocalShare, .userDotLocalState, .userDotLocalBin] {
            XCTAssertFalse(
                swept.contains(domain),
                "\(domain) reached the leftovers sweep. ~/.config/git belongs to git, which "
                + "is installed, and the sweep has no way to know that yet."
            )
        }
    }

    /// The uninstall path does search here, because it starts from an
    /// application that is genuinely going.
    func testTheUninstallPathStillSearchesThemEvenThoughTheSweepDoesNot() throws {
        let config = try make(.userDotConfig, "app")
        let identity = Identity(bundleID: "com.example.app", name: "App")

        let found = LocationInventorySource(budget: { .unlimited })
            .findings(for: identity, in: root).evidence

        XCTAssertTrue(
            found.contains { $0.url.standardizedFileURL.path == config.standardizedFileURL.path }
        )
    }

    /// Somebody else's tool keeps its own settings.
    func testAnotherToolsSettingsAreLeftAlone() throws {
        try make(.userDotConfig, "git")
        let mine = try make(.userDotConfig, "app")
        let identity = Identity(bundleID: "com.example.app", name: "App")

        let paths = Set(
            LocationInventorySource(budget: { .unlimited })
                .findings(for: identity, in: root).evidence
                .map { $0.url.standardizedFileURL.path }
        )

        XCTAssertTrue(paths.contains(mine.standardizedFileURL.path))
        XCTAssertFalse(
            paths.contains(root.url(for: .userDotConfig)
                .appendingPathComponent("git").standardizedFileURL.path),
            "git's settings are git's."
        )
    }
}
