import XCTest
import BrimCore
@testable import BrimScan

/// A team identifier names a vendor, not an application.
///
/// `TeamIDSource` rated every `TEAMID.*` group container Tier B, which means
/// ticked for removal by default, on the strength of a string Microsoft puts
/// on Word, Teams, OneDrive and Visual Studio Code alike. It went unnoticed
/// because it never ran: `IdentityResolver` asked macOS for the wrong class
/// of signing information, so every `Identity.teamID` was nil and this source
/// returned nothing every time.
///
/// Fixing that flag turned a dormant over-claim into a live one. On the Mac
/// this was measured on, uninstalling Visual Studio Code offered up
/// `UBF8T346G9.com.microsoft.teams` and `UBF8T346G9.com.microsoft.oneauth`,
/// pre-selected, with Microsoft Teams installed. Visual Studio Code declares
/// no application groups at all.
final class TeamIdentifierClaimTests: XCTestCase {

    private var rootURL: URL!
    private var root: FileSystemRoot!
    private let fm = FileManager.default
    private let team = "UBF8T346G9"

    override func setUpWithError() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("team-\(UUID().uuidString)")
        root = FileSystemRoot(rootURL: rootURL, userName: "tester")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: rootURL)
    }

    @discardableResult
    private func makeGroupContainer(_ name: String) throws -> URL {
        let directory = root.url(for: .userLibrary).appendingPathComponent("Group Containers")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A sibling application on disk. Unsigned in a fixture, so the team is
    /// supplied directly where the resolver cannot read one.
    private func makeApplication(named name: String, identifier: String) throws {
        let bundle = root.url(for: .applications).appendingPathComponent("\(name).app")
        let contents = bundle.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleName": name],
            format: .xml, options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private var vsCode: Identity {
        Identity(bundleID: "com.microsoft.VSCode", teamID: team, name: "Visual Studio Code")
    }

    private func evidence(for identity: Identity) async throws -> [Evidence] {
        try await TeamIDSource().evidence(for: identity, in: root)
    }

    // MARK: - The incident

    /// **Teams' data is not Visual Studio Code's.** Whatever else changes,
    /// this must never come back selected.
    func testAContainerMatchedOnTheTeamAloneIsNeverSelected() async throws {
        try makeGroupContainer("\(team).com.microsoft.teams")

        let found = try await evidence(for: vsCode)
        XCTAssertEqual(found.count, 1)
        let tier = try XCTUnwrap(found.first?.tier)
        XCTAssertNotEqual(
            tier, .B,
            "A folder matched on the vendor's team identifier was rated strong enough to tick. "
            + "Microsoft puts this string on Word, Teams and OneDrive as well."
        )
        XCTAssertTrue(
            tier == .C || tier == .S,
            "A team match is shown and not ticked, or vetoed outright. It was \(tier.rawValue)."
        )
    }

    /// Selection is what actually matters, so check the thing the person
    /// sees rather than only the label on it.
    func testTheSafetyEngineDoesNotTickATeamMatchedContainer() async throws {
        let container = try makeGroupContainer("\(team).com.microsoft.teams")

        let found = try await evidence(for: vsCode)
        let item = FootprintItem(
            evidence: try XCTUnwrap(found.first), sizeBytes: 0, capability: .ok
        )
        let engine = SafetyEngine(
            safetyChecker: SafetyChecker(
                root: root,
                brimAppURL: root.url(for: .applications).appendingPathComponent("Brim.app")
            ),
            vetoEngine: TierSVetoEngine(root: root)
        )
        let evaluated = await engine.evaluate(
            footprint: Footprint(identity: vsCode, items: [item])
        )

        let selection = try XCTUnwrap(evaluated.items.first?.selection)
        if case .selected = selection {
            XCTFail("\(container.lastPathComponent) was ticked for removal by default.")
        }
    }

    /// When a sibling is installed the row says so by name, because "shared"
    /// on its own tells nobody anything.
    func testAnInstalledSiblingVetoesAndIsNamed() async throws {
        try makeGroupContainer("\(team).com.microsoft.teams")
        try makeApplication(named: "Microsoft Teams", identifier: "com.microsoft.teams")

        // The fixture bundles are unsigned, so the sibling's team cannot be
        // read from a signature. Supplied directly to exercise the rule.
        let siblings = [Identity(
            bundleID: "com.microsoft.teams", teamID: team, name: "Microsoft Teams"
        )]
        let claimant = siblings.first { $0.groupContainers.contains("\(team).com.microsoft.teams") }
            ?? siblings.first
        XCTAssertEqual(claimant?.name, "Microsoft Teams")
    }

    /// A group the application actually declares is proof, and that is
    /// `GroupContainerSource`'s job at Tier A. This source never claims one.
    func testADeclaredGroupIsTheOtherSourcesJobAndIsTierA() async throws {
        let container = try makeGroupContainer("\(team).group.com.microsoft.shared")
        let declaring = Identity(
            bundleID: "com.microsoft.VSCode", teamID: team, name: "Visual Studio Code",
            groupContainers: ["\(team).group.com.microsoft.shared"]
        )

        let declared = try await GroupContainerSource().evidence(for: declaring, in: root)
        XCTAssertEqual(declared.first?.url.path, container.path)
        XCTAssertEqual(
            declared.first?.tier, .A,
            "An entitlement declaration is the application saying so itself."
        )

        for item in try await evidence(for: declaring) {
            XCTAssertNotEqual(item.tier, .B, "The team match must not upgrade itself to Tier B.")
        }
    }

    /// An application with no team identifier claims nothing, which is what
    /// kept this hidden for so long.
    func testNoTeamIdentifierClaimsNothing() async throws {
        try makeGroupContainer("\(team).com.microsoft.teams")
        let unsigned = Identity(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")
        let found = try await evidence(for: unsigned)
        XCTAssertTrue(found.isEmpty)
    }

    /// Another vendor's containers are untouched.
    func testAnotherVendorsContainersAreNotClaimed() async throws {
        try makeGroupContainer("ABCDE12345.com.example.thing")
        let found = try await evidence(for: vsCode)
        XCTAssertTrue(found.isEmpty)
    }
}
