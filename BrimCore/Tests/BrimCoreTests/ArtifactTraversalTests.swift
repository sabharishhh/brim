import BrimCore
import Foundation
import Testing

struct ArtifactTraversalTests {
    @Test func aSmallEntryBudgetReturnsAVisiblePartialFloor() throws {
        let fixture = try TraversalFixture()
        for name in ["first", "second", "third"] {
            try fixture.put("output/\(name)", bytes: 32)
        }
        let folder = fixture.root.appendingPathComponent("output")
        let limited = ArtifactSizer.measure(at: folder, maximumEntries: 2)
        #expect(limited.state == .partial)
        #expect(limited.logicalBytes == 64)
        #expect(limited.completeness.timedOut == [folder.path])
        #expect(limited.isEmpty == false)
        let complete = ArtifactSizer.measure(at: folder, maximumEntries: 3)
        #expect(complete.state == .complete)
        #expect(complete.logicalBytes == 96)
    }

    @Test func aLinkedRootIsNeverOpenedEvenWithNoEntryBudget() throws {
        let fixture = try TraversalFixture()
        let target = try fixture.put("outside/large", bytes: 8192).deletingLastPathComponent()
        let link = fixture.root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let measured = ArtifactSizer.measure(at: link, maximumEntries: 0)
        #expect(measured.state == .complete)
        #expect(measured.logicalBytes == Int64(target.path.utf8.count))
        #expect(measured.logicalBytes < 8192)
    }

    @Test func aLinkedChildAndHiddenFileAreMeasuredWithoutOpeningTheLinkedTree() throws {
        let fixture = try TraversalFixture()
        try fixture.put("output/.hidden", bytes: 32)
        let target = try fixture.put("outside/large", bytes: 8192).deletingLastPathComponent()
        let link = fixture.root.appendingPathComponent("output/linked-child")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let measured = ArtifactSizer.measure(at: link.deletingLastPathComponent(), maximumEntries: 2)
        #expect(measured.state == .complete)
        #expect(measured.logicalBytes == 32 + Int64(target.path.utf8.count))
    }

    @Test func theFilesystemRootSubsumesEveryChildRoot() {
        let roots = ArtifactSizer.minimalRoots([
            URL(fileURLWithPath: "/private/tmp/one"), URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/private/tmp")
        ])
        #expect(roots.map(\.path) == ["/"])
    }
}

private final class TraversalFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("traversal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult func put(_ path: String, bytes: Int) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: file)
        return file
    }
}
