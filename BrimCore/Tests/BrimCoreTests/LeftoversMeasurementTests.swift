import BrimCore
import BrimScan
import Darwin
import Foundation
import XCTest

final class LeftoversMeasurementTests: XCTestCase {
    func testHiddenContentsAreMeasuredWithoutFollowingLinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = FileSystemRoot(rootURL: directory, userName: "fixture")
        let folder = root.url(for: .userApplicationSupport).appendingPathComponent("UnknownFixture")
        let hidden = folder.appendingPathComponent(".hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 512).write(to: folder.appendingPathComponent("data"))
        try Data(repeating: 2, count: 256).write(to: hidden.appendingPathComponent("settings"))
        let external = directory.appendingPathComponent("other-data")
        try Data(repeating: 3, count: 4096).write(to: external)
        let link = folder.appendingPathComponent("reference")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let linkSize = try FileManager.default.attributesOfItem(atPath: link.path)[.size] as? Int64
        let scanner = LeftoversScanner(root: root, commandIsInstalled: { _ in false })
        let items = try await scanner.scanLeftovers()
        let item = items.first { $0.url.lastPathComponent == "UnknownFixture" }
        XCTAssertEqual(item?.size, 768 + (linkSize ?? 0))
        XCTAssertEqual(item?.sizeIsKnown, true)
    }

    func testUnreadableFolderIsNotDiscardedAsEmpty() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires ordinary user file permissions") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = FileSystemRoot(rootURL: directory, userName: "fixture")
        let folder = root.url(for: .userApplicationSupport).appendingPathComponent("UnknownFixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1024).write(to: folder.appendingPathComponent("data"))
        defer {
            chmod(folder.path, 0o700)
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertEqual(chmod(folder.path, 0), 0)
        let scanner = LeftoversScanner(root: root, commandIsInstalled: { _ in false })
        let items = try await scanner.scanLeftovers()
        let item = items.first { $0.url.lastPathComponent == "UnknownFixture" }
        XCTAssertNotNil(item, "A failed size read is not proof that the folder is empty")
        XCTAssertEqual(item?.sizeIsKnown, false)
    }
}
