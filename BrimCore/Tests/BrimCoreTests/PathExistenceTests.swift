import XCTest
@testable import BrimCore
@testable import BrimScan

/// A broken symlink is standing right there, and `fileExists` says it is not.
///
/// The incident: fourteen broken links on a real Mac, left by a removed Zed,
/// a removed Docker and a removed Python framework. `/usr/local/bin/zed`
/// points at `/Applications/Zed.app/Contents/MacOS/cli` and that application
/// has gone. The sweep found all fourteen, grouped them, and ticked them.
/// Pressing Review and Remove opened a sheet with an empty list, "Frees now:
/// Empty", and an Authorize button.
///
/// `FootprintProjector` guarded on `fileExists(atPath:)`, which follows the
/// link and asks about the target. False for every one, so nothing reached
/// the plan. `Executor` had the same guard and would have written
/// `already_gone` a second time. `verify` was already using `lstat`, with a
/// comment explaining exactly why, so one component knew and three did not.
///
/// The shape of the failure is the bad part: Brim would have reported a
/// successful removal having removed nothing, and the links would still be
/// there.
final class PathExistenceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("existence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func danglingLink(named name: String = "link") throws -> URL {
        let link = directory.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: directory.appendingPathComponent("gone").path
        )
        return link
    }

    func testABrokenLinkExistsEvenThoughItsTargetDoesNot() throws {
        let link = try danglingLink()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: link.path),
            "This is the trap: fileExists follows the link and answers about the target"
        )
        XCTAssertTrue(
            PathExistence.exists(at: link),
            "The link itself is on the disk and is the thing being removed"
        )
    }

    func testALinkThatResolvesAlsoExists() throws {
        let target = directory.appendingPathComponent("real")
        try Data("x".utf8).write(to: target)
        let link = directory.appendingPathComponent("good")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertTrue(PathExistence.exists(at: link))
        XCTAssertFalse(PathExistence.isDanglingSymlink(atPath: link.path))
    }

    func testABrokenLinkIsToldApartFromAWorkingOne() throws {
        XCTAssertTrue(PathExistence.isDanglingSymlink(atPath: try danglingLink().path))
    }

    func testSomethingAbsentIsStillAbsent() {
        XCTAssertFalse(PathExistence.exists(at: directory.appendingPathComponent("nothing")))
        XCTAssertFalse(PathExistence.isDanglingSymlink(
            atPath: directory.appendingPathComponent("nothing").path
        ))
    }

    func testAPlainFileAndADirectoryBothExist() throws {
        let file = directory.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        XCTAssertTrue(PathExistence.exists(at: file))
        XCTAssertTrue(PathExistence.exists(at: directory))
    }

    // MARK: - The part that actually broke

    /// The projector is where the fourteen items were lost. Naming them as
    /// explicit targets is exactly what the Leftovers screen does when
    /// somebody ticks rows and presses Review and Remove.
    func testBrokenLinksNamedForRemovalReachTheFootprint() async throws {
        let links = try (1...3).map { try danglingLink(named: "cli-\($0)") }

        let evidence = links.map {
            Evidence(url: $0, tier: .A, mechanism: "DirectTarget",
                     humanSentence: "Specific target requested by intent")
        }
        let footprint = try await FootprintProjector(engine: EvidenceEngine(sources: []))
            .project(
                identity: Identity(bundleID: "com.test.gone", name: "Gone"),
                in: FileSystemRoot(rootURL: directory),
                explicitEvidence: evidence
            )

        XCTAssertEqual(
            footprint.items.count, 3,
            "Every broken link was dropped before it could become a plan step, so the "
            + "removal sheet opened empty and Authorize would have done nothing"
        )
    }

    /// Size, separately, because a link takes no space and the panel has to
    /// say so rather than report the size of whatever it used to point at.
    func testABrokenLinkCountsAsNoSpace() async throws {
        let link = try danglingLink()
        let footprint = try await FootprintProjector(engine: EvidenceEngine(sources: []))
            .project(
                identity: Identity(bundleID: "com.test.gone", name: "Gone"),
                in: FileSystemRoot(rootURL: directory),
                explicitEvidence: [Evidence(url: link, tier: .A, mechanism: "DirectTarget",
                                            humanSentence: "because")]
            )
        XCTAssertEqual(footprint.items.first?.sizeBytes, 0)
    }
}
