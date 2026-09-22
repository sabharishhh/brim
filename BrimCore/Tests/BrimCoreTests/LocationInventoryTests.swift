import XCTest
import BrimCore
@testable import BrimScan

/// Sixty-odd locations, each with a rule for how a match there is proved.
///
/// Brim resolved nineteen, which is fewer than AppCleaner reaches, and
/// the hard-coded nine in `BundleIdentifierComponentSource` were the ones
/// that mattered for an uninstall. A path on its own is not enough
/// though: the specification says each location needs an evidence rule,
/// and a location Brim can only name-match is Tier C and must be
/// labelled as one.
final class LocationInventoryTests: XCTestCase {

    func testTheInventoryIsActuallyWide() {
        // The number is not the point, the coverage is, but nineteen was
        // measurably less than the field.
        XCTAssertGreaterThan(
            LocationInventory.standard.locations.count, 40,
            "The inventory is back to being narrower than a competitor's"
        )
    }

    func testEveryLocationSaysHowItKnows() {
        for location in LocationInventory.standard.locations {
            XCTAssertFalse(
                location.sentence.isEmpty,
                "\(location.domain) has no sentence, so a row from it could not say why"
            )
            XCTAssertFalse(location.describes.isEmpty)
        }
    }

    func testAnIdentifierMatchIsStrongerThanANameMatch() {
        // A bundle identifier is a reverse-DNS name nobody else uses. A
        // human name is not: two products called "Studio" is ordinary.
        let byIdentifier = LocationInventory.Location(
            domain: .userApplicationSupport, rule: .bundleIdentifier,
            describes: "x", sentence: "x"
        )
        let byName = LocationInventory.Location(
            domain: .userApplicationSupport, rule: .applicationName,
            describes: "x", sentence: "x"
        )
        XCTAssertEqual(byIdentifier.tier, .B)
        XCTAssertEqual(byName.tier, .C, "A name match must never be selected by default")
    }

    func testALocationThatCanOnlyBeNameMatchedIsTierCWhateverTheRuleSays() {
        // /usr/local/bin holds a binary with no bundle and no identifier.
        // The only thing linking it to an application is a shared name,
        // so the domain floors the tier no matter how the row is written.
        let optimistic = LocationInventory.Location(
            domain: .usrLocalBin, rule: .bundleIdentifier,
            describes: "x", sentence: "x"
        )
        XCTAssertEqual(optimistic.tier, .C)
    }

    func testEveryCommandLineLocationIsTierC() {
        let commandLine: [FileSystemRoot.Domain] = [
            .usrLocalBin, .usrLocalSbin, .usrLocalOpt,
            .usrLocalEtc, .usrLocalShare, .usrLocalVar,
        ]
        for location in LocationInventory.standard.locations
        where commandLine.contains(location.domain) {
            XCTAssertEqual(
                location.tier, .C,
                "\(location.domain) is matched on a name and must be shown, not selected"
            )
        }
    }

    func testTheLocationsThatWereInvisibleAreCovered() {
        // Each of these is named in the strategy document as a place
        // software hides that Brim could not see at all.
        let mustBePresent: [FileSystemRoot.Domain] = [
            .userPreferencesByHost,
            .userAudioComponents, .systemAudioComponents, .systemAudioVST3,
            .userInternetPlugIns, .userPreferencePanes, .userServices,
            .userQuickLook, .userSpotlight, .userAutomator, .userColorPickers,
            .userScreenSavers, .userWidgets,
            .systemExtensionsFolder, .startupItems,
            .userDiagnosticReports, .systemDiagnosticReports,
            .usrLocalBin, .sharedApplicationSupport,
            .darwinUserCache, .darwinUserTemp,
        ]
        let covered = Set(LocationInventory.standard.locations.map(\.domain))
        for domain in mustBePresent {
            XCTAssertTrue(covered.contains(domain), "\(domain) is still not looked at")
        }
    }

    func testAnAudioPlugInIsAttributedByWhatIsInsideIt() {
        // An Audio Unit's file name says nothing about who made it, so
        // the only rule available reads the bundle's own Info.plist.
        // Every path-matching scanner in the field misses these.
        let audio = LocationInventory.standard.locations.filter {
            $0.domain == .systemAudioComponents || $0.domain == .systemAudioVST3
        }
        XCTAssertFalse(audio.isEmpty)
        for location in audio {
            XCTAssertEqual(location.rule, .identifierInsideBundle)
        }
    }

    func testTheDarwinFoldersStayInsideAFixtureRoot() {
        // Answering with the real machine's /var/folders while scanning a
        // shadow tree would walk the developer's own cache.
        let fixture = FileSystemRoot(rootURL: URL(fileURLWithPath: "/tmp/fixture-root"))
        let cache = fixture.url(for: .darwinUserCache).path
        XCTAssertTrue(cache.hasPrefix("/tmp/fixture-root"), cache)

        let real = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        XCTAssertFalse(real.url(for: .darwinUserCache).path.hasPrefix("/tmp/fixture-root"))
    }

    func testReceiptsPointAtWhereTheyActuallyAre() {
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        XCTAssertEqual(
            root.url(for: .systemReceipts).path, "/private/var/db/receipts",
            "/Library/Receipts is the old location and is empty on a modern Mac"
        )
    }
}

/// Finding things in those locations, on a tree built for the purpose.
final class LocationInventorySourceTests: XCTestCase {

    private var rootURL: URL!
    private var root: FileSystemRoot!

    override func setUpWithError() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inventory-\(UUID().uuidString)")
        root = FileSystemRoot(rootURL: rootURL, userName: "tester")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func make(_ domain: FileSystemRoot.Domain, _ name: String, bundleID: String? = nil) throws -> URL {
        let directory = root.url(for: domain)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = directory.appendingPathComponent(name)
        if let bundleID {
            let contents = item.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0
            )
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        } else {
            try Data("x".utf8).write(to: item)
        }
        return item
    }

    private var identity: Identity {
        Identity(bundleID: "com.example.studio", name: "Studio")
    }

    func testByHostPreferencesAreFound() throws {
        // A second copy of the settings that a scan of Preferences walks
        // straight past.
        let file = try make(
            .userPreferencesByHost,
            "com.example.studio.00000000-0000-1000-8000-0123456789AB.plist"
        )
        let found = LocationInventorySource(budget: { .unlimited })
            .findings(for: identity, in: root)

        XCTAssertTrue(found.evidence.contains { $0.url.path == file.path }, "ByHost was missed")
    }

    func testAnAudioUnitIsFoundByWhatIsInsideIt() throws {
        // The file name says "Reverb". Only the Info.plist says who made
        // it, which is why every path-matching scanner misses these.
        let unit = try make(
            .systemAudioComponents, "Reverb.component", bundleID: "com.example.studio"
        )
        let found = LocationInventorySource(budget: { .unlimited })
            .findings(for: identity, in: root)

        XCTAssertTrue(found.evidence.contains { $0.url.path == unit.path })
        XCTAssertEqual(
            found.evidence.first { $0.url.path == unit.path }?.tier, .B,
            "The identifier came from the bundle itself, which is not a guess"
        )
    }

    func testSomebodyElsesAudioUnitIsLeftAlone() throws {
        _ = try make(.systemAudioComponents, "Reverb.component", bundleID: "com.other.maker")
        let found = LocationInventorySource(budget: { .unlimited })
            .findings(for: identity, in: root)

        XCTAssertTrue(
            found.evidence.isEmpty,
            "A plug-in belonging to somebody else was claimed: \(found.evidence.map(\.url.path))"
        )
    }

    func testACommandLineToolIsFoundAndNotSelected() throws {
        let tool = try make(.usrLocalBin, "Studio")
        let found = LocationInventorySource(budget: { .unlimited })
            .findings(for: identity, in: root)

        let match = found.evidence.first { $0.url.path == tool.path }
        XCTAssertNotNil(match, "A command line tool with the app's name was missed")
        XCTAssertEqual(match?.tier, .C, "Nothing links these but a shared name")
        XCTAssertTrue(
            match?.humanSentence.contains("share a name") ?? false,
            "A Tier C row has to admit what it is: \(match?.humanSentence ?? "")"
        )
    }

    func testABudgetThatHasRunOutStopsTheExpensiveWorkAndSaysSo() throws {
        _ = try make(.systemAudioComponents, "Reverb.component", bundleID: "com.example.studio")

        let exhausted = ScanBudget(total: -1, perProbe: 0)
        let found = LocationInventorySource(budget: { exhausted }).findings(for: identity, in: root)

        XCTAssertTrue(found.evidence.isEmpty, "The plug-in walk should have been skipped")
        XCTAssertFalse(found.completeness.isComplete)
        XCTAssertFalse(found.completeness.timedOut.isEmpty)

        // The sentence has to carry two things, not one. Saying only that a
        // place went unread leaves somebody holding a shortfall with nothing
        // to do about it, so it also names what would fix it.
        let explanation = found.completeness.explanation ?? ""
        XCTAssertTrue(explanation.contains("longer"), explanation)
        XCTAssertTrue(explanation.lowercased().contains("again"), explanation)
    }

    func testTheCheapChecksStillRunWhenTimeIsShort() throws {
        // Asking whether one path exists is a single lstat. A run already
        // out of time still gets the certain answers, because skipping
        // them buys nothing.
        let support = try make(.userApplicationSupport, "com.example.studio")
        let found = LocationInventorySource(budget: { ScanBudget(total: -1, perProbe: 0) })
            .findings(for: identity, in: root)

        XCTAssertTrue(found.evidence.contains { $0.url.path == support.path })
    }

    // MARK: - The updater's cache

    /// **`<identifier>.ShipIt`.** An application installed by any route can
    /// switch to updating itself afterwards, and Squirrel leaves its working
    /// folder in Caches under the identifier with a suffix. Caches had an
    /// exact identifier rule, which walks straight past it, and three of the
    /// six applications measured on this Mac were carrying one that their
    /// own uninstall would not have removed.
    func testASuffixedIdentifierFolderInCachesIsFound() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrimPrefix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FileSystemRoot(rootURL: root)
        let caches = fileSystem.url(for: .userCaches)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)

        let shipIt = caches.appendingPathComponent("com.example.app.ShipIt")
        let exact = caches.appendingPathComponent("com.example.app")
        // A different product whose identifier merely starts with the same
        // letters. The prefix is the identifier and a dot for this reason.
        let neighbour = caches.appendingPathComponent("com.example.applet")
        for url in [shipIt, exact, neighbour] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let identity = Identity(bundleID: "com.example.app", name: "App")
        let found = LocationInventorySource().findings(for: identity, in: fileSystem).evidence
        let paths = Set(found.map { $0.url.standardizedFileURL.path })

        XCTAssertTrue(
            paths.contains(shipIt.standardizedFileURL.path),
            "The updater's own cache is this application's and was not found."
        )
        XCTAssertTrue(paths.contains(exact.standardizedFileURL.path))
        XCTAssertFalse(
            paths.contains(neighbour.standardizedFileURL.path),
            "com.example.applet is somebody else's and a prefix rule reached it."
        )
    }

    /// A suffixed identifier folder in Application Support is the same shape
    /// and the common case for anything shipping a helper or an XPC service.
    func testASuffixedIdentifierFolderInApplicationSupportIsFound() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrimPrefix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = FileSystemRoot(rootURL: root)
        let support = fileSystem.url(for: .userApplicationSupport)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let helper = support.appendingPathComponent("com.example.app.helper")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)

        let identity = Identity(bundleID: "com.example.app", name: "App")
        let found = LocationInventorySource().findings(for: identity, in: fileSystem).evidence

        XCTAssertTrue(
            found.contains { $0.url.standardizedFileURL == helper.standardizedFileURL },
            "A helper's folder under the application's own identifier was not found."
        )
    }

    /// An identifier match stays Tier B when the rule gains a prefix. The
    /// evidence is still a reverse-DNS string nobody else uses.
    func testAPrefixedIdentifierMatchIsStillAnIdentifierMatch() {
        let prefixed = LocationInventory.standard.locations.filter {
            $0.domain == .userCaches && $0.rule == .bundleIdentifierPrefix
        }
        XCTAssertFalse(prefixed.isEmpty, "Caches lost its identifier rule entirely.")
        for location in prefixed {
            XCTAssertEqual(location.tier, .B)
        }
    }
}

/// An unfinished search does not get to select anything.
final class FailClosedScanTests: XCTestCase {

    private func evaluate(completeness: ScanCompleteness) async -> EvaluatedItem {
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/tmp/fail-closed"))
        let engine = SafetyEngine(
            safetyChecker: SafetyChecker(
                root: root, brimAppURL: URL(fileURLWithPath: "/tmp/fail-closed/Brim.app")
            ),
            vetoEngine: TierSVetoEngine(root: root)
        )
        let item = FootprintItem(
            evidence: Evidence(
                url: URL(fileURLWithPath: "/tmp/fail-closed/thing"), tier: .A,
                mechanism: "test", humanSentence: "because"
            ),
            sizeBytes: 1, capability: .ok
        )
        let footprint = Footprint(
            identity: Identity(bundleID: "com.example.app", name: "Example"),
            items: [item], completeness: completeness
        )
        return await engine.evaluate(footprint: footprint).items[0]
    }

    func testAFinishedSearchSelectsAsBefore() async {
        if case .selected = await evaluate(completeness: .complete).selection {} else {
            XCTFail("A complete scan should still select Tier A")
        }
    }

    func testATimedOutSearchSelectsNothing() async {
        // Mole degrades a timed-out scan and narrows the plan rather than
        // removing shared leftovers. A footprint is a claim about what is
        // on the disk, and an unfinished search cannot support it.
        let evaluated = await evaluate(
            completeness: ScanCompleteness(timedOut: ["/Library/Audio/Plug-Ins/Components"])
        )
        if case .unselected = evaluated.selection {} else {
            XCTFail("An unfinished scan pre-selected something: \(evaluated.selection)")
        }
    }

    func testAnUnreadableLocationAlsoNarrowsTheSelection() async {
        let evaluated = await evaluate(
            completeness: ScanCompleteness(unreadable: ["/Library/Application Support"])
        )
        if case .unselected = evaluated.selection {} else {
            XCTFail("An unreadable location left the selection wide: \(evaluated.selection)")
        }
    }

    func testTheItemsAreStillShown() async {
        // Narrowing the selection, not the list. Everything found is
        // still there and every row can still be ticked by hand.
        let evaluated = await evaluate(completeness: ScanCompleteness(timedOut: ["/x"]))
        if case .excluded = evaluated.selection {
            XCTFail("An unfinished scan hid the row instead of unticking it")
        }
    }

    func testTheGapIsSaidOutLoud() {
        XCTAssertNil(ScanCompleteness.complete.explanation)
        XCTAssertTrue(
            ScanCompleteness(timedOut: ["/a", "/b"]).explanation?.contains("2 places") ?? false
        )
        XCTAssertTrue(
            ScanCompleteness(unreadable: ["/a"]).explanation?.contains("1 place") ?? false
        )
    }
}
