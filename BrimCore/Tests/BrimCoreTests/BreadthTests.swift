import XCTest
import BrimCore
@testable import BrimScan

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
        let found = Set(try await NestedFolderSource().evidence(for: identity, in: root).map(\.url.standardizedFileURL))
        XCTAssertTrue(found.contains(sdk.standardizedFileURL))
        XCTAssertTrue(found.contains(hidden.standardizedFileURL))
        XCTAssertFalse(found.contains(nameOnly.standardizedFileURL), "a name alone never counts")
        XCTAssertFalse(found.contains(documents.standardizedFileURL))
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
        let parts = Set(EvidenceEngine.parts(in: evidence, excluding: []).map { $0.0.lastPathComponent })
        XCTAssertEqual(parts, ["SampleUpdater.app", "Agent.app"])
    }
}
