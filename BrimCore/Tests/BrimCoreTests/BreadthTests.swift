import BrimCore
@testable import BrimScan
import XCTest

/// Reach, not rules for particular apps.
///
/// On a real Mac, Brim found 15 of the 17 things Antigravity had left, and
/// both misses were one class: something the app kept inside a folder that
/// was not its own, `~/.gemini/antigravity` among them. Searching by name
/// alone would have caught them and also caught Python's `antigravity.py`
/// and somebody's `~/Documents/antigravity`. These hold the line between.
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

    /// Inside another application's folder, an identifier in somebody
    /// else's namespace is shipped by other applications too. eqMac's
    /// removal ticked Codex's Sparkle cache this way.
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

    /// Sentry keeps an application's crash reports under its bundle name,
    /// `Caches/SentryCrash/eqMac`, and nothing else names them. The name
    /// counts only because the bundle ships Sentry.
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

    private func component(_ path: String, _ identifier: String) -> IdentitySurface.Component {
        IdentitySurface.Component(path: path, bundleIdentifier: identifier,
                                  name: (path as NSString).lastPathComponent, bundleName: nil,
                                  teamIdentifier: "TEAM", groups: [], urlSchemes: [], exportedTypes: [])
    }

    /// A helper application inside one of the app's folders, or run by one
    /// of its launch jobs, names more of the app. One in an Applications
    /// folder is another application and is not followed.
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
