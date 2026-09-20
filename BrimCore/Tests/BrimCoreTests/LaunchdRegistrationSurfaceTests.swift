import XCTest
import BrimCore
@testable import BrimScan

/// Parsing and ownership rules for launchd registrations, against a synthetic
/// tree so the result does not depend on whose Mac runs it.
final class LaunchdRegistrationSurfaceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func writeJob(
        domain: String,
        fileName: String,
        label: String?,
        program: String?
    ) throws {
        let dir = root.appendingPathComponent(domain)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var dict: [String: Any] = [:]
        if let label { dict["Label"] = label }
        if let program { dict["ProgramArguments"] = [program, "--daemon"] }

        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent(fileName))
    }

    private func scan() async -> [Registration] {
        await LaunchdRegistrationSurface().registrations(
            in: FileSystemRoot(rootURL: root, userName: "tester")
        )
    }

    func testAJobWhoseProgramIsMissingIsReportedStale() async throws {
        try writeJob(
            domain: "Users/tester/Library/LaunchAgents",
            fileName: "com.example.ghost.plist",
            label: "com.example.ghost",
            program: root.appendingPathComponent("Applications/Gone.app/Contents/MacOS/Gone").path
        )

        let found = await scan()
        let ghost = try XCTUnwrap(found.first { $0.identifier == "com.example.ghost" })

        XCTAssertTrue(ghost.isStale, "A job pointing at a missing program is exactly the stale entry to surface")
        XCTAssertEqual(ghost.kind, .launchdJob)
        XCTAssertTrue(ghost.evidence.contains("missing"), "The sentence should say why it is stale")
    }

    func testAJobWhoseProgramExistsIsNotStale() async throws {
        let program = root.appendingPathComponent("Applications/Live.app/Contents/MacOS/Live")
        try FileManager.default.createDirectory(
            at: program.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "binary".write(to: program, atomically: true, encoding: .utf8)

        try writeJob(
            domain: "Users/tester/Library/LaunchAgents",
            fileName: "com.example.live.plist",
            label: "com.example.live",
            program: program.path
        )

        let found = await scan()
        let live = try XCTUnwrap(found.first { $0.identifier == "com.example.live" })
        XCTAssertFalse(live.isStale)
    }

    func testEveryDomainIsSearched() async throws {
        try writeJob(domain: "Users/tester/Library/LaunchAgents",
                     fileName: "com.example.user.plist", label: "com.example.user", program: nil)
        try writeJob(domain: "Library/LaunchAgents",
                     fileName: "com.example.localagent.plist", label: "com.example.localagent", program: nil)
        try writeJob(domain: "Library/LaunchDaemons",
                     fileName: "com.example.localdaemon.plist", label: "com.example.localdaemon", program: nil)

        let labels = Set(await scan().map(\.identifier))
        XCTAssertTrue(labels.contains("com.example.user"), "user LaunchAgents missed")
        XCTAssertTrue(labels.contains("com.example.localagent"), "local LaunchAgents missed")
        XCTAssertTrue(labels.contains("com.example.localdaemon"), "local LaunchDaemons missed")
    }

    func testAJobWithNoLabelFallsBackToItsFileNameRatherThanBeingDropped() async throws {
        // launchd itself falls back to the file name, so a plist without a
        // Label is still a live job and must not vanish from the inventory.
        try writeJob(domain: "Users/tester/Library/LaunchAgents",
                     fileName: "com.example.unlabelled.plist", label: nil, program: nil)

        let found = await scan()
        XCTAssertTrue(found.contains { $0.identifier == "com.example.unlabelled" })
    }

    func testMalformedPlistsAreSkippedWithoutFailingTheScan() async throws {
        let dir = root.appendingPathComponent("Users/tester/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "this is not a plist".write(
            to: dir.appendingPathComponent("broken.plist"), atomically: true, encoding: .utf8
        )
        try writeJob(domain: "Users/tester/Library/LaunchAgents",
                     fileName: "com.example.ok.plist", label: "com.example.ok", program: nil)

        let found = await scan()
        XCTAssertTrue(found.contains { $0.identifier == "com.example.ok" },
                      "One unreadable plist must not stop the rest of the scan")
        XCTAssertFalse(found.contains { $0.identifier == "broken" })
    }

    func testAppleJobsInSystemDomainsAreNotOfferedAsCleanable() async throws {
        // Apple ships launchd jobs whose programs are absent. They are not
        // leftovers, they cannot be removed, and a sweep that lists them is
        // telling the user to delete part of macOS.
        try writeJob(
            domain: "System/Library/LaunchDaemons",
            fileName: "com.apple.ghost.plist",
            label: "com.apple.ghost",
            program: root.appendingPathComponent("System/Installation/gone").path
        )

        let found = await scan()
        let apple = try XCTUnwrap(found.first { $0.identifier == "com.apple.ghost" })

        XCTAssertTrue(apple.isStale, "It does point at a missing program")
        XCTAssertTrue(apple.isSystemOwned)
        XCTAssertFalse(apple.isActionableStale, "But it must never be offered as cleanable")

        let inventory = RegistrationInventory(surfaces: [LaunchdRegistrationSurface()])
        let sweep = await inventory.stale(in: FileSystemRoot(rootURL: root, userName: "tester"))
        XCTAssertFalse(sweep.contains { $0.identifier == "com.apple.ghost" },
                       "The sweep must exclude entries macOS owns")
    }

    func testAThirdPartyStaleJobIsStillSwept() async throws {
        try writeJob(
            domain: "Users/tester/Library/LaunchAgents",
            fileName: "com.vendor.ghost.plist",
            label: "com.vendor.ghost",
            program: root.appendingPathComponent("Applications/Vendor.app/Contents/MacOS/V").path
        )

        let inventory = RegistrationInventory(surfaces: [LaunchdRegistrationSurface()])
        let sweep = await inventory.stale(in: FileSystemRoot(rootURL: root, userName: "tester"))
        XCTAssertTrue(sweep.contains { $0.identifier == "com.vendor.ghost" })
    }

    // MARK: - Ownership

    func testOwnershipMatchesOnBundleIdentifierNotOnSubstring() {
        let job = Registration(
            kind: .launchdJob,
            identifier: "com.example.suite.helper",
            label: "com.example.suite.helper",
            owningBundleID: "com.example.suite.helper",
            programPath: nil,
            targetExists: true,
            evidence: "test"
        )

        // The neighbouring app must not claim it just because its identifier
        // is a prefix — that is how an uninstall removes a sibling's job.
        let neighbour = Identity(bundleID: "com.example.suite", name: "Suite")
        XCTAssertFalse(job.belongs(to: neighbour, bundleURL: nil))

        let owner = Identity(bundleID: "com.example.suite.helper", name: "Helper")
        XCTAssertTrue(job.belongs(to: owner, bundleURL: nil))
    }

    func testOwnershipMatchesAProgramInsideTheAppBundle() {
        let bundle = URL(fileURLWithPath: "/Applications/Example.app")
        let job = Registration(
            kind: .launchdJob,
            identifier: "totally.unrelated.label",
            label: "totally.unrelated.label",
            owningBundleID: nil,
            programPath: "/Applications/Example.app/Contents/MacOS/Helper",
            targetExists: true,
            evidence: "test"
        )

        let identity = Identity(bundleID: "com.example.app", name: "Example")
        XCTAssertTrue(
            job.belongs(to: identity, bundleURL: bundle),
            "A job launching a binary inside the bundle belongs to it however it is labelled"
        )
    }

    func testAProgramPathThatMerelySharesAPrefixIsNotOwned() {
        let bundle = URL(fileURLWithPath: "/Applications/Example.app")
        let job = Registration(
            kind: .launchdJob,
            identifier: "x",
            label: "x",
            owningBundleID: nil,
            // "/Applications/Example.app.backup/..." shares the prefix but is
            // a different bundle.
            programPath: "/Applications/Example.app.backup/Contents/MacOS/Helper",
            targetExists: true,
            evidence: "test"
        )

        XCTAssertFalse(job.belongs(to: Identity(bundleID: "com.example.app", name: "Example"), bundleURL: bundle))
    }
}
