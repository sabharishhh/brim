import BrimCore
@testable import BrimScan
import XCTest

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
        // A footprint is a claim about the disk, and an unfinished search cannot
        // support it, so nothing is selected.
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
        // The selection narrows, not the list: everything found is still there and
        // tickable by hand.
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

    /// Matching uses set lookups and a name's own dotted prefixes rather than
    /// testing every identifier against every file, with exactly the same
    /// boundaries as the string comparison had.
    func testMatchingKeepsItsBoundariesWithManyIdentifiers() {
        let identity = Identity(bundleID: "com.vendor.app", name: "App")
        func tier(_ rule: LocationInventory.Rule, _ name: String, declared: String? = nil) -> EvidenceTier? {
            LocationInventory.Location(domain: .userCaches, rule: rule, describes: "", sentence: "")
                .matchTier(name: name, identity: identity, declaredIdentifier: declared)
        }
        XCTAssertNotNil(tier(.bundleIdentifierPrefix, "com.vendor.app"))
        XCTAssertNotNil(tier(.bundleIdentifierPrefix, "com.vendor.app.plist"))
        XCTAssertNotNil(tier(.bundleIdentifierPrefix, "com.vendor.app.helper.cache"))
        XCTAssertNil(tier(.bundleIdentifierPrefix, "com.vendor.apple"), "a longer word is not a prefix")
        XCTAssertNil(tier(.bundleIdentifierPrefix, "com.vendor"))
        XCTAssertNotNil(tier(.bundleIdentifierFile("plist"), "com.vendor.app.plist"))
        XCTAssertNil(tier(.bundleIdentifierFile("plist"), "com.vendor.app.helper.plist"))
        XCTAssertNotNil(tier(.clientOfService, "com.apple.WebKit.GPU+com.vendor.app"))
        XCTAssertNotNil(tier(.identifierInsideBundle, "Plugin.bundle", declared: "com.vendor.app.plugin"))
        XCTAssertNil(tier(.identifierInsideBundle, "Plugin.bundle", declared: "com.vendor.apps"))
        XCTAssertEqual(tier(.groupContainer, "group.com.vendor.app"), .C)
        XCTAssertNil(tier(.groupContainer, "group.com.vendor"))
    }

    private func location(
        _ rule: LocationInventory.Rule,
        _ domain: FileSystemRoot.Domain
    ) -> LocationInventory.Location {
        LocationInventory.standard.locations.first { $0.rule == rule && $0.domain == domain }!
    }

    /// An editor's home folder declared in `product.json` (`.vscode`) is a
    /// record and Tier B; the same folder found by name is Tier C.
    func testAHomeFolderTheBundleDeclaresIsTierBAndANameMatchIsTierC() {
        let surface = IdentitySurface(bundlePath: "/Applications/Antigravity.app", components: [
            .init(path: "/Applications/Antigravity.app", bundleIdentifier: "com.google.antigravity",
                  name: "Antigravity", bundleName: nil, teamIdentifier: nil, groups: [], urlSchemes: [],
                  exportedTypes: [])
        ], homeFolders: [".vscode"])
        let identity = Identity(bundleID: "com.google.antigravity", name: "Antigravity", identitySurface: surface)
        let home = location(.homeDotFolder, .userHomeDotFolders)
        XCTAssertEqual(home.matchTier(name: ".vscode", identity: identity), .B)
        XCTAssertEqual(home.matchTier(name: ".antigravity", identity: identity), .C)
        XCTAssertEqual(home.matchTier(name: ".antigravity-ide", identity: identity), .C)
        XCTAssertNil(home.matchTier(name: ".antigravityx", identity: identity))
        XCTAssertNil(home.matchTier(name: "antigravity", identity: identity))
    }

    /// Crash reports carry the process name and a date, never the name alone.
    func testACrashReportIsMatchedByProcessNameAndDate() {
        let reports = location(.diagnosticReport, .systemDiagnosticReports)
        let tally = Identity(bundleID: "com.example.tally.app", name: "Tally")
        XCTAssertEqual(reports.matchTier(name: "Tally_2026-09-29-090414_host.cpu_resource.diag", identity: tally), .C)
        XCTAssertEqual(reports.matchTier(name: "Tally-2026-09-29-090414.ips", identity: tally), .C)
        XCTAssertNil(reports.matchTier(name: "Tally-Helper-2026-09-29-090414.ips", identity: tally))
        XCTAssertNil(reports.matchTier(name: "Tallying_2026-09-29-090414.ips", identity: tally))
    }
}
