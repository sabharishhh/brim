import XCTest
import BrimCore
@testable import BrimScan

/// Old versions of a command line tool are offered only on a link's word:
/// the command points at one version, and nothing points at the rest.
final class OldVersionsTests: XCTestCase {
    private var home: URL!
    private var bin: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ov-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    @discardableResult
    private func version(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: url)
        return url
    }

    private func link(_ name: String, to target: URL, in folder: URL? = nil) throws {
        try FileManager.default.createSymbolicLink(at: (folder ?? bin).appendingPathComponent(name),
                                                   withDestinationURL: target)
    }

    private func scan() -> [DeveloperCache] {
        OldVersionsScanner(commandFolders: [bin], home: home).scan(home: home)
    }

    func testTheVersionTheCommandRunsStaysAndTheRestAreOffered() throws {
        let current = try version(".local/share/claude/versions/2.1.281")
        try version(".local/share/claude/versions/2.1.260")
        try link("claude", to: current)

        let found = scan()
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["2.1.260"])
        XCTAssertEqual(found.first?.versionInUse, "2.1.281")
        XCTAssertEqual(found.first?.tool, "claude")
        XCTAssertTrue(found.first?.explanation.contains("claude runs 2.1.281") == true)
    }

    func testALinkIntoAVersionsBinCountsItsVersion() throws {
        let current = try version(".local/share/tool/versions/3.0/bin/tool")
        try version(".local/share/tool/versions/2.0/bin/tool")
        try link("tool", to: current)
        XCTAssertEqual(scan().map(\.url.lastPathComponent), ["2.0"])
    }

    func testAPointerInsideTheFolderProtectsWhatItNames() throws {
        let current = try version(".local/share/tool/versions/3.0")
        let pinned = try version(".local/share/tool/versions/2.0")
        try version(".local/share/tool/versions/1.0")
        try link("tool", to: current)
        try link("current", to: pinned, in: home.appendingPathComponent(".local/share/tool/versions"))
        XCTAssertEqual(scan().map(\.url.lastPathComponent), ["1.0"])
    }

    /// nvm and mise choose a version from a shell hook or a project file,
    /// which leaves no link. Nothing there is offered.
    func testNoLinkMeansNothingIsOffered() throws {
        try version(".nvm/versions/node/v20.1.0/bin/node")
        try version(".nvm/versions/node/v18.0.0/bin/node")
        XCTAssertTrue(scan().isEmpty)
    }

    func testABrokenCommandOffersNothing() throws {
        try version(".local/share/claude/versions/2.1.260")
        try link("claude", to: home.appendingPathComponent(".local/share/claude/versions/9.9.9"))
        XCTAssertTrue(scan().isEmpty)
    }

    func testAVersionsFolderOutsideHomeIsNeverRead() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("ov-out-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: outside) }
        let current = outside.appendingPathComponent("tool/versions/2")
        try FileManager.default.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: current)
        try Data([1]).write(to: outside.appendingPathComponent("tool/versions/1"))
        try link("tool", to: current)
        XCTAssertTrue(scan().isEmpty)
    }

    func testTwoCommandsIntoOneFolderKeepBothVersions() throws {
        let a = try version(".local/share/kit/versions/2/bin/a")
        let b = try version(".local/share/kit/versions/1/bin/b")
        try version(".local/share/kit/versions/0/bin/a")
        try link("a", to: a)
        try link("b", to: b)
        XCTAssertEqual(scan().map(\.url.lastPathComponent), ["0"])
    }
}
