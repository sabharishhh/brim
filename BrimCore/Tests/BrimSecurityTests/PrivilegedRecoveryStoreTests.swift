@testable import BrimPrivileged
import Darwin
import XCTest

final class PrivilegedRecoveryStoreTests: XCTestCase {
    private var root: URL!
    private var store: PrivilegedRecoveryStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recovery-\(UUID().uuidString)")
        try folder(root)
        store = PrivilegedRecoveryStore(root: root, expectedOwner: getuid())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    private func file(_ name: String, contents: String = "record") throws -> URL {
        let parent = root.appendingPathComponent("2026-10-03T00-00-00Z/Applications")
        try folder(parent)
        let url = parent.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testRecoveryCopiesAreListedAndOnlyTheSelectedCopyIsRemoved() throws {
        // Privileged removals were retained invisibly, leaving an app copy
        // that macOS continued to recognise after uninstalling it.
        let first = try file("First.plist")
        let second = try file("Second.plist")
        let items = try store.items()
        XCTAssertEqual(items.count, 2)
        let item = try XCTUnwrap(items.first { $0.name == "First.plist" })
        XCTAssertEqual(item.sizeBytes, 6)
        XCTAssertTrue(item.sizeIsKnown)
        try store.remove(identifier: item.identifier, expectedDevice: item.dev, expectedInode: item.ino)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try store.items().map(\.name), ["Second.plist"])
    }

    func testReplacementAfterReviewIsRefused() throws {
        let url = try file("Selected.plist")
        let item = try XCTUnwrap(store.items().first)
        // Keep the old inode alive, so the filesystem cannot reuse it.
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("old"))
        try Data("replacement".utf8).write(to: url)
        XCTAssertThrowsError(try store.remove(
            identifier: item.identifier, expectedDevice: item.dev, expectedInode: item.ino
        ))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "replacement")
    }

    func testNamesCannotEscapeTheStore() throws {
        _ = try file("Selected.plist")
        let invalid = ["../Applications/Selected.plist", "stamp//Selected.plist",
                       "/stamp/source/name", "stamp/source/../name"]
        for identifier in invalid {
            XCTAssertThrowsError(try store.remove(identifier: identifier, expectedDevice: 0, expectedInode: 0))
        }
    }

    func testSymlinkedDirectoryAndWritableStoreAreRefused() throws {
        let outside = root.appendingPathComponent("Outside")
        try folder(outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Redirect"),
                                                   withDestinationURL: outside)
        XCTAssertThrowsError(try store.items())
        try FileManager.default.removeItem(at: root.appendingPathComponent("Redirect"))
        try FileManager.default.removeItem(at: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        XCTAssertThrowsError(try store.items())
    }

    func testARecoveryLinkRemovesOnlyTheLink() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("target-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let url = try file("command")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        let item = try XCTUnwrap(store.items().first)
        try store.remove(identifier: item.identifier, expectedDevice: item.dev, expectedInode: item.ino)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    }

    func testBundlesHaveIdentityWithoutWalkingTheirContentsForSize() throws {
        let bundle = root.appendingPathComponent("2026-10-03T00-00-00Z/Applications/Example.app")
        try folder(bundle.appendingPathComponent("Contents"))
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "org.example.application"], format: .xml, options: 0
        )
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let item = try XCTUnwrap(store.items().first)
        XCTAssertEqual(item.bundleID, "org.example.application")
        XCTAssertFalse(item.sizeIsKnown)
        XCTAssertEqual(item.sizeBytes, 0)
    }

    func testOversizedRecoveryListingFailsInsteadOfReportingAnIncompleteList() throws {
        for number in 0 ..< PrivilegedRecoveryStore.entryLimit {
            _ = try file("entry-\(number)")
        }
        XCTAssertThrowsError(try store.items())
    }
}
