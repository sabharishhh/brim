import BrimCore
@testable import BrimScan
import XCTest

/// A launchd job whose label starts with a team identifier belongs to the
/// developer, not necessarily to the application being removed.
///
/// `LaunchdSource` claimed any such job at Tier A, the strongest there is, so
/// it was selected by default and the plan would unload it and remove its
/// property list. Like `TeamIDSource` it had never run, because
/// `Identity.teamID` was nil everywhere until `IdentityResolver` asked macOS
/// for the right class of signing information. The same fix that made the
/// team identifier resolve made this reachable, and a suite that registers
/// one `TEAMID.helper` for several applications would have had it unloaded
/// by the removal of any one of them.
final class LaunchdTeamClaimTests: XCTestCase {
    private var rootURL: URL!
    private var root: FileSystemRoot!
    private let fm = FileManager.default
    private let team = "ABCDE12345"

    override func setUpWithError() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("launchd-\(UUID().uuidString)")
        root = FileSystemRoot(rootURL: rootURL, userName: "tester")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: rootURL)
    }

    @discardableResult
    private func makeJob(label: String, program: String = "/usr/local/libexec/helper") throws -> URL {
        let directory = root.url(for: .systemLaunchDaemons)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(label).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": label, "Program": program], format: .xml, options: 0
        )
        try data.write(to: url)
        return url
    }

    private var editor: Identity {
        Identity(bundleID: "com.example.editor", teamID: team, name: "Editor")
    }

    private func evidence() async throws -> [Evidence] {
        try await LaunchdSource().evidence(for: editor, in: root)
    }

    /// **The line.** A job matched on the team identifier alone is never
    /// selected, because nothing about it says which of the developer's
    /// applications it serves.
    func testAJobMatchedOnTheTeamAloneIsNeverTickedForRemoval() async throws {
        try makeJob(label: "\(team).com.example.sharedhelper")

        let found = try await evidence()
        XCTAssertEqual(found.count, 1)
        let tier = try XCTUnwrap(found.first?.tier)
        XCTAssertFalse(
            tier == .A || tier == .B,
            "A launchd job matched on the developer's team identifier was rated \(tier.rawValue). "
                + "It would be unloaded along with this application, whichever of the developer's "
                + "applications it actually serves."
        )
    }

    /// A job the application's own identifier names is still the
    /// application's, at full strength. The fix must not cost recall on the
    /// ordinary case.
    func testAJobNamedAfterTheApplicationIsStillDirect() async throws {
        try makeJob(label: "com.example.editor.helper")

        let found = try await evidence()
        XCTAssertEqual(found.first?.tier, .A)
    }

    /// A team-prefixed job whose program lives inside this application's
    /// bundle is proven by the program, not by the label, and stays direct.
    func testATeamPrefixedJobRunningFromInsideTheBundleIsStillDirect() async throws {
        let bundle = root.url(for: .applications).appendingPathComponent("Editor.app")
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents"),
                               withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.editor"],
            format: .xml, options: 0
        )
        try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let program = bundle.appendingPathComponent("Contents/Library/LaunchServices/helper").path
        try makeJob(label: "\(team).com.example.helper", program: program)

        let found = try await evidence()
        XCTAssertEqual(
            found.first?.tier, .A,
            "The program lives inside this application's bundle, which is proof."
        )
    }

    /// A job from a different developer is untouched.
    func testAnotherDevelopersJobIsNotClaimed() async throws {
        try makeJob(label: "ZZZZZ99999.com.other.helper")
        let found = try await evidence()
        XCTAssertTrue(found.isEmpty)
    }
}
