import XCTest
import BrimCore
@testable import BrimScan

/// What a size is, and what it is not: the bundle in the list, everything
/// the app wrote in the detail. These protect the arithmetic.
final class FootprintMeasurementTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("measure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, bytes: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func testPlainFilesAddUp() throws {
        _ = try write("a", bytes: 1000)
        _ = try write("b", bytes: 2000)

        let measured = FootprintProjector.measure(at: directory, fm: .default)

        XCTAssertEqual(measured.bytes, 3000)
        XCTAssertEqual(measured.unreadable, 0)
    }

    func testAHardlinkIsOneFileAndNotTwo() throws {
        // Two names, one file: counted once, because the bytes come back once.
        let original = try write("original", bytes: 5000)
        let second = directory.appendingPathComponent("second")
        try FileManager.default.linkItem(at: original, to: second)

        let measured = FootprintProjector.measure(at: directory, fm: .default)

        XCTAssertEqual(measured.bytes, 5000, "One file with two names is 5000 bytes, not 10000")
    }

    func testASymlinkIsTheLinkAndNotWhatItPointsAt() throws {
        // A link is measured as itself; following it would add its target's size.
        let big = try write("big", bytes: 100_000)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)

        let measured = FootprintProjector.measure(at: directory, fm: .default)

        XCTAssertLessThan(measured.bytes, 101_000,
                          "The link is a few bytes, not another copy of the target")
        XCTAssertGreaterThanOrEqual(measured.bytes, 100_000)
    }

    func testASingleFileIsMeasuredWithoutWalkingAnything() throws {
        let file = try write("only", bytes: 4096)
        XCTAssertEqual(FootprintProjector.measure(at: file, fm: .default).bytes, 4096)
    }

    func testSomethingThatIsNotThereWeighsNothingAndSaysNothingIsWrong() {
        let missing = directory.appendingPathComponent("never-existed")
        let measured = FootprintProjector.measure(at: missing, fm: .default)

        XCTAssertEqual(measured.bytes, 0)
        XCTAssertEqual(measured.unreadable, 0, "Absent is not the same as unreadable")
    }

    func testAnUnreadableTotalIsReportedRatherThanLookingComplete() throws {
        // Unreadable entries are counted, so a short total says it is short.
        _ = try write("readable", bytes: 100)
        let locked = directory.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        _ = try Data(repeating: 0x41, count: 900).write(to: locked.appendingPathComponent("hidden"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        try XCTSkipIf(getuid() == 0, "Root reads everything, so there is nothing to refuse")

        let measured = FootprintProjector.measure(at: directory, fm: .default)

        XCTAssertGreaterThan(measured.unreadable, 0,
                             "An unreadable subtree has to be counted, not silently skipped")
    }

    func testTheFootprintCarriesTheGapUpToTheView() {
        let item = FootprintItem(
            evidence: Evidence(url: URL(fileURLWithPath: "/tmp/x"), tier: .A,
                               mechanism: "test", humanSentence: "because"),
            sizeBytes: 10, capability: .ok, unreadableEntries: 3
        )
        let footprint = Footprint(identity: Identity(bundleID: "a", name: "A"), items: [item])

        XCTAssertEqual(footprint.unreadableEntries, 3)
    }
}

/// One spelling of a size everywhere: `ByteText`, never `ByteCountFormatter`.
final class ByteTextConsistencyTests: XCTestCase {

    func testNothingFormatsSizesByItself() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ByteText.swift" } ?? []
        XCTAssertFalse(files.isEmpty)

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                text.contains("ByteCountFormatter"),
                "\(file.lastPathComponent) formats a size itself. ByteText is the one spelling, "
                + "and the raw formatter writes \"Zero KB\"."
            )
        }
    }
}
