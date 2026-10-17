@testable import BrimCore
@testable import BrimScan
import Darwin
import XCTest

/// A broken symbolic link is there, and `fileExists` says it is not. A
/// guard on `fileExists` dropped broken links from the plan, so a removal
/// reported success having removed nothing.
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
        XCTAssertTrue(try PathExistence.isDanglingSymlink(atPath: danglingLink().path))
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

    /// Broken links named for removal reach the footprint, as Remnants names
    /// them.
    func testBrokenLinksNamedForRemovalReachTheFootprint() async throws {
        let links = try (1 ... 3).map { try danglingLink(named: "cli-\($0)") }

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

    /// A broken link counts its own stored bytes, never the absent target.
    func testABrokenLinkCountsOnlyItsOwnStoredBytes() async throws {
        let link = try danglingLink()
        let footprint = try await FootprintProjector(engine: EvidenceEngine(sources: []))
            .project(
                identity: Identity(bundleID: "com.test.gone", name: "Gone"),
                in: FileSystemRoot(rootURL: directory),
                explicitEvidence: [Evidence(url: link, tier: .A, mechanism: "DirectTarget",
                                            humanSentence: "because")]
            )
        var information = stat()
        XCTAssertEqual(lstat(link.path, &information), 0)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(information.st_size, Int64(destination.utf8.count))
        XCTAssertEqual(footprint.items.first?.sizeBytes, information.st_size)
        XCTAssertEqual(footprint.items.first?.sizeMeasurement?.state, .complete)
        XCTAssertTrue(footprint.completeness.isComplete)
    }
}
