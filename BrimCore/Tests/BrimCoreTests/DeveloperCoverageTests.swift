import BrimCore
@testable import BrimOps
@testable import BrimScan
import XCTest

/// What Developer finds, held to what this Mac actually had.
///
/// The largest thing any tool had left was a Rust project's 20 GB `target`
/// folder, and the Developer list could not see it: it only knew fixed
/// cache paths, and a project lives wherever its owner put it. npx, uv,
/// node-gyp and clang's caches were missing too, and turned up in
/// Leftovers as "owner unknown" instead.
final class DeveloperCoverageTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("dev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    @discardableResult
    private func put(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: url)
        return url
    }

    private func scanner() -> ProjectBuildScanner {
        ProjectBuildScanner(search: { _, _ in nil })
    }

    func testABuildFolderCountsOnlyBesideTheFileThatRebuildsIt() throws {
        try put("Developer/loki/Cargo.toml")
        try put("Developer/loki/target/debug/libloki.a")
        // Called `build`, with nothing that would make it again.
        try put("Developer/notes/build/draft.txt")
        // A dependency's own manifest is not a project.
        try put("Developer/web/package.json")
        try put("Developer/web/package-lock.json")
        try put("Developer/web/node_modules/left-pad/package.json")
        try put("Developer/web/node_modules/left-pad/index.js")
        // No lock file: reinstalling might not give the same packages back.
        try put("Developer/loose/package.json")
        try put("Developer/loose/node_modules/x/index.js")

        let found = scanner().scan(home: home)
        XCTAssertEqual(Set(found.map { $0.url.lastPathComponent + "@" + $0.tool }),
                       ["target@loki", "node_modules@web"])
        XCTAssertTrue(found.allSatisfy(\.isProject))
        XCTAssertEqual(found.first { $0.tool == "loki" }?.cost, .rebuilt)
        XCTAssertEqual(found.first { $0.tool == "web" }?.cost, .restored)
        XCTAssertTrue(found.first { $0.tool == "loki" }?.explanation.contains("cargo build") == true)
    }

    func testTheNewToolCachesAreFoundAndClaimedFromLeftovers() throws {
        let darwin = home.appendingPathComponent("darwin")
        try put(".npm/_npx/abc/package.json")
        try put(".cache/uv/archive/x")
        try put("Library/Caches/node-gyp/22.0/include")
        try put("Library/Caches/vscode-cpptools/ipch/x")
        let clang = darwin.appendingPathComponent("clang/ModuleCache/x.pcm")
        try FileManager.default.createDirectory(
            at: clang.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1]).write(to: clang)

        let caches = DeveloperCacheScanner(
            home: home,
            darwinCache: darwin,
            projects: nil,
            updates: nil,
            oldVersions: nil
        )
        let tools = try Set(XCTUnwrap(awaitResult { await caches.scan() }).map(\.tool))
        XCTAssertTrue(tools.isSuperset(of: ["npx", "uv", "node-gyp", "VS Code C/C++", "Clang"]), "\(tools)")

        let claimed = DeveloperCacheScanner.claimedPaths(home: home, darwinCache: darwin)
        XCTAssertTrue(claimed.contains(darwin.appendingPathComponent("clang").standardizedFileURL.path))
        XCTAssertTrue(claimed.contains(home.appendingPathComponent("Library/Caches/node-gyp").standardizedFileURL.path))
    }

    /// Cargo hard-links its build outputs, and a 20 GB `target` read 35 GB
    /// because every name was counted. Removing the folder frees each file
    /// once.
    func testAFileWithSeveralNamesIsCountedOnce() throws {
        let file = try put("Developer/loki/target/deps/lib.a")
        try Data(repeating: 7, count: 1_000_000).write(to: file)
        let link = home.appendingPathComponent("Developer/loki/target/debug/lib.a")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: file, to: link)
        let once = DeveloperCacheScanner.size(of: file.deletingLastPathComponent())
        XCTAssertEqual(DeveloperCacheScanner.size(of: home.appendingPathComponent("Developer/loki/target")), once)
    }

    /// `cargo cache` is an add-on almost nobody has, and `gradle --stop`
    /// deletes nothing. Neither is offered as a cleanup any more.
    func testCleanupsThatCouldNotWorkAreGone() {
        XCTAssertNil(ToolCleanup.command(id: "cargo.cache"))
        XCTAssertNil(ToolCleanup.command(id: "gradle.cache"))
        XCTAssertNotNil(ToolCleanup.command(id: "uv.cache"))
    }

    /// Opened from Finder, an app's PATH is the system folders only, and
    /// every cleanup needing npm, pnpm, brew or uv said the tool was missing.
    func testCleanupsCanFindToolsInstalledOutsideTheSystemFolders() {
        let path = ToolCleanup.environment()["PATH"] ?? ""
        XCTAssertTrue(path.split(separator: ":").contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.split(separator: ":").contains("/usr/local/bin"))
    }

    private func awaitResult<T>(_ work: @escaping @Sendable () async -> T) -> T? {
        let expectation = expectation(description: "scan")
        nonisolated(unsafe) var result: T?
        Task { result = await work(); expectation.fulfill() }
        wait(for: [expectation], timeout: 10)
        return result
    }
}
