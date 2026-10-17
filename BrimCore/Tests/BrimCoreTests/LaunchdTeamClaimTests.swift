import BrimCore
@testable import BrimScan
import XCTest

/// A launchd job whose label starts with a team identifier belongs to the
/// developer, not necessarily to the app being removed, so it is never
/// ticked: a helper shared by a suite would be unloaded with any one app.
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

    /// A job matched on the team alone is never selected.
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

    /// A job named for the app's own identifier is still direct.
    func testAJobNamedAfterTheApplicationIsStillDirect() async throws {
        try makeJob(label: "com.example.editor.helper")

        let found = try await evidence()
        XCTAssertEqual(found.first?.tier, .A)
    }

    /// A team-prefixed job running from inside the bundle is proven by its
    /// program and stays direct.
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
