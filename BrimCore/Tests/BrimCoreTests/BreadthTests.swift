import BrimCore
@testable import BrimScan
import XCTest

/// Reach, not rules for particular apps: an app's data inside a folder that
/// is not its own (`~/.gemini/antigravity`) is found, while Python's
/// `antigravity.py` and `~/Documents/antigravity` are not.
final class BreadthTests: XCTestCase {
    private var rootURL: URL!
    private var root: FileSystemRoot!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("breadth-\(UUID().uuidString)")
        root = FileSystemRoot(rootURL: rootURL, userName: "tester")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }

    @discardableResult
    private func put(_ relative: String) throws -> URL {
        let url = rootURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
        return url.deletingLastPathComponent()
    }

    func testAChildNamedWithTheIdentifierInsideAnotherFolderIsFound() async throws {
        let sdk = try put("Users/tester/Library/Caches/com.crashlytics/com.example.sample/data")
        let hidden = try put("Users/tester/.shared-tool/com.example.sample/state")
        // Named for the app, with nothing to say the app wrote it.
        let nameOnly = try put("Users/tester/.shared-tool/sample/state")
        // The person's own folder is never read.
        let documents = try put("Users/tester/Documents/com.example.sample/notes")

        let identity = Identity(bundleID: "com.example.sample", name: "Sample")
        let found = try await Set(NestedFolderSource().evidence(for: identity, in: root).map(\.url.standardizedFileURL))
        XCTAssertTrue(found.contains(sdk.standardizedFileURL))
        XCTAssertTrue(found.contains(hidden.standardizedFileURL))
        XCTAssertFalse(found.contains(nameOnly.standardizedFileURL), "a name alone never counts")
        XCTAssertFalse(found.contains(documents.standardizedFileURL))
    }

    /// Inside another app's folder, an identifier in someone else's namespace
    /// ships in other apps too, so it is only a name match.
    func testAnotherNamespaceInsideAnotherFolderIsOnlyANameMatch() async throws {
        let foreign = try put("Users/tester/Library/Caches/com.other.app/com.vendor.shared/data")
        let own = try put("Users/tester/Library/Caches/com.other.app/com.example.sample.agent/data")
        let surface = IdentitySurface(bundlePath: "/Applications/Sample.app", components: [
            component("/Applications/Sample.app", "com.example.sample"),
            component("/Applications/Sample.app/Contents/XPCServices/S.xpc", "com.vendor.shared")
        ])
        let identity = Identity(bundleID: "com.example.sample", name: "Sample", identitySurface: surface)
        let tiers = try await Dictionary(
            NestedFolderSource().evidence(for: identity, in: root).map { ($0.url.standardizedFileURL, $0.tier) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(tiers[foreign.standardizedFileURL], .C)
        XCTAssertEqual(tiers[own.standardizedFileURL], .B)
    }

    /// `Caches/SentryCrash/<bundle name>` counts only because the bundle ships
    /// Sentry.
    func testACrashReporterFolderCountsOnlyWhenTheBundleShipsIt() async throws {
        let reports = try put("Users/tester/Library/Caches/SentryCrash/Sample/Reports/r")
        let other = try put("Users/tester/Library/Caches/SentryCrash/Sampler/Reports/r")
        func identity(shipping frameworks: [String]) -> Identity {
            let surface = IdentitySurface(bundlePath: "/Applications/Sample.app", components: [
                component("/Applications/Sample.app", "com.example.sample")
            ] + frameworks.map { component("/Applications/Sample.app/Contents/Frameworks/\($0)", "io.sdk") })
            return Identity(bundleID: "com.example.sample", name: "Sample", identitySurface: surface)
        }
        let withSentry = try await Set(NestedFolderSource().evidence(for: identity(shipping: ["Sentry.framework"]),
                                                                     in: root).map(\.url.standardizedFileURL))
        XCTAssertTrue(withSentry.contains(reports.deletingLastPathComponent().standardizedFileURL))
        XCTAssertFalse(withSentry.contains(other.deletingLastPathComponent().standardizedFileURL))
        let without = try await NestedFolderSource().evidence(for: identity(shipping: []), in: root)
        XCTAssertTrue(without.isEmpty)
    }

    /// `Caches/io.sentry/<SHA-1 of the DSN>` counts when the DSN in the app's
    /// executable hashes to the folder's name; another app's folder does not.
    func testASentryFolderCountsWhenItIsNamedForTheAddressInTheApp() async throws {
        let address = "https://afd95e4c332b4b1da4bb23b9cc66782c@sentry.io/1243254"
        XCTAssertEqual(CrashReporterFolders.sha1(address), "a456d41a8479da4fe7ad5452565d41fafe14cb35")
        let bundle = rootURL.appendingPathComponent("Applications/Sample.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/Sample")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(("\0\0junk" + address + "\0more").utf8).write(to: executable)
        let ours = try put("Users/tester/Library/Caches/io.sentry/a456d41a8479da4fe7ad5452565d41fafe14cb35/s")
        let theirs = try put("Users/tester/Library/Caches/io.sentry/0123456789abcdef0123456789abcdef01234567/s")
        let surface = IdentitySurface(bundlePath: bundle.path, components: [
            IdentitySurface.Component(path: bundle.path, bundleIdentifier: "com.example.sample", name: "Sample",
                                      bundleName: nil, executableName: "Sample", teamIdentifier: "TEAM",
                                      groups: [], urlSchemes: [], exportedTypes: []),
            component(bundle.path + "/Contents/Frameworks/Sentry.framework", "io.sentry.Sentry")
        ])
        let identity = Identity(bundleID: "com.example.sample", name: "Sample", bundlePath: bundle.path,
                                identitySurface: surface)
        let found = try await Set(NestedFolderSource().evidence(for: identity, in: root).map(\.url.standardizedFileURL))
        XCTAssertTrue(found.contains(ours.standardizedFileURL))
        XCTAssertFalse(found.contains(theirs.standardizedFileURL))
    }

    private func component(_ path: String, _ identifier: String) -> IdentitySurface.Component {
        IdentitySurface.Component(path: path, bundleIdentifier: identifier,
                                  name: (path as NSString).lastPathComponent, bundleName: nil,
                                  teamIdentifier: "TEAM", groups: [], urlSchemes: [], exportedTypes: [])
    }

    /// A helper app inside one of the app's folders, or run by its launch job,
    /// names more of the app; one in an Applications folder is another app.
    func testTheTrailFollowsHelpersButNotOtherApplications() throws {
        let support = rootURL.appendingPathComponent("Users/tester/Library/Application Support/Sample")
        let helper = support.appendingPathComponent("Updater/SampleUpdater.app")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        let other = rootURL.appendingPathComponent("Applications/Other.app")
        let job = rootURL.appendingPathComponent("Users/tester/Library/LaunchAgents/com.example.sample.agent.plist")
        try FileManager.default.createDirectory(at: job.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "Label": "com.example.sample.agent",
            "ProgramArguments": [rootURL.path + "/Library/Application Support/Sample/Agent.app/Contents/MacOS/agent"]
        ], format: .xml, options: 0).write(to: job)

        let evidence = [
            Evidence(url: support, tier: .B, mechanism: "LocationInventorySource", humanSentence: ""),
            Evidence(url: other, tier: .B, mechanism: "LocationInventorySource", humanSentence: ""),
            Evidence(url: job, tier: .B, mechanism: "LaunchdSource", humanSentence: "")
        ]
        let parts = Set(EvidenceEngine.parts(in: evidence, excluding: []).map(\.0.lastPathComponent))
        XCTAssertEqual(parts, ["SampleUpdater.app", "Agent.app"])
    }
}
