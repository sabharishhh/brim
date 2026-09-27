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

    /// The sweep reaches these locations now that it checks executable
    /// ownership before offering a command line tool's data.
    func testTheLeftoversSweepIncludesDotFolders() {
        let swept = Set(LocationInventory.sweepDomains)
        for domain in [FileSystemRoot.Domain.userDotConfig, .userDotCache,
                       .userDotLocalShare, .userDotLocalState, .userDotLocalBin] {
            XCTAssertTrue(swept.contains(domain))
        }
    }

    func testInstalledCommandKeepsItsSettingsButDepartedDataIsOffered() async throws {
        let gitSettings = try make(.userDotConfig, "git")
        let departed = try make(.userDotConfig, "departed")
        try "settings".write(to: gitSettings.appendingPathComponent("config"),
                             atomically: true, encoding: .utf8)
        try "settings".write(to: departed.appendingPathComponent("config"),
                             atomically: true, encoding: .utf8)

        let leftovers = try await LeftoversScanner(
            root: root, commandIsInstalled: { $0 == "git" }
        ).scanLeftovers()
        let names = Set(leftovers.map(\.url.lastPathComponent))
        XCTAssertFalse(names.contains("git"))
        XCTAssertTrue(names.contains("departed"))
    }

    func testLocalExecutableProtectsItsDotFolderWithoutShellPath() async throws {
        let commandName = "brimfixturetool"
        let settings = try make(.userDotConfig, commandName)
        try "settings".write(to: settings.appendingPathComponent("config"),
                             atomically: true, encoding: .utf8)
        let bin = root.url(for: .userDotLocalBin)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let command = bin.appendingPathComponent(commandName)
        try "#!/bin/sh\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)

        let leftovers = try await LeftoversScanner(root: root).scanLeftovers()
        XCTAssertFalse(leftovers.contains { $0.url.lastPathComponent == commandName })
    }

    /// The forward search still finds the same data after the sweep widens.
    func testTheUninstallPathStillSearchesDotFolders() throws {
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
