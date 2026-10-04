import BrimCore
@testable import BrimScan
import Darwin
import Foundation
import Testing

struct SizingPresenceTests {
    @Test(arguments: ["missing", "ordinary-file/child"])
    func provenAbsenceHasCompleteZeroSizeWithoutReadGaps(relative: String) async throws {
        let fixture = try PresenceSizingFixture()
        try fixture.put("ordinary-file")
        let missing = fixture.root.appendingPathComponent(relative)
        let measured = ArtifactSizer.measure(at: missing)
        #expect(measured.state == .complete)
        #expect(measured.isEmpty)
        #expect(measured.logicalBytes == 0)
        #expect(measured.allocatedBytes == 0)
        #expect(measured.completeness.isComplete)
        let evidence = fixture.evidence(missing)
        let account = await StorageAccountant().account(for: [FootprintItem(
            evidence: evidence, sizeBytes: 32, capability: .ok
        )])
        #expect(account.measurement.state == .complete)
        #expect(account.logical == 0)
        #expect(account.measurement.completeness.isComplete)
        let projected = try await fixture.project(evidence)
        #expect(projected.items.isEmpty)
        #expect(projected.logicalSizeBytes == 0)
        #expect(projected.completeness.isComplete)
    }

    @Test func aLoopInAnAncestorRemainsUnknownAndReachesTheFootprint() async throws {
        let fixture = try PresenceSizingFixture()
        let loop = fixture.root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
        let target = loop.appendingPathComponent("child")
        try await expectUnknown(target, error: ELOOP, fixture: fixture)
    }

    @Test(.enabled(if: getuid() != 0))
    func aRefusedAncestorRemainsUnknownAndReachesTheFootprint() async throws {
        let fixture = try PresenceSizingFixture()
        let target = try fixture.put("refused/child")
        let folder = target.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        try await expectUnknown(target, error: EACCES, fixture: fixture)
    }

    private func expectUnknown(_ target: URL, error: Int32, fixture: PresenceSizingFixture) async throws {
        var information = stat()
        let result = lstat(target.path, &information)
        let failure = errno
        try #require(result == -1)
        try #require(failure == error)
        let measured = ArtifactSizer.measure(at: target)
        #expect(measured.state == .unknown)
        #expect(measured.isEmpty == false)
        #expect(measured.completeness.unreadable == [target.path])
        let evidence = fixture.evidence(target)
        let account = await StorageAccountant().account(for: [FootprintItem(
            evidence: evidence, sizeBytes: 32, capability: .ok
        )])
        #expect(account.measurement.state == .unknown)
        #expect(account.measurement.completeness.unreadable == [target.path])
        let projected = try await fixture.project(evidence)
        #expect(projected.items.count == 1)
        #expect(projected.items.first?.sizeMeasurement?.state == .unknown)
        #expect(projected.completeness.unreadable == [target.path])
        #expect(projected.completeness.isComplete == false)
    }
}

private final class PresenceSizingFixture: Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sizing-presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult func put(_ path: String) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: file)
        return file
    }

    func evidence(_ target: URL) -> Evidence {
        Evidence(url: target, tier: .A, mechanism: "DirectTarget", humanSentence: "Chosen path.")
    }

    func project(_ evidence: Evidence) async throws -> Footprint {
        try await FootprintProjector(engine: EvidenceEngine(sources: [])).project(
            identity: Identity(name: "Fixture"), in: FileSystemRoot(rootURL: root), explicitEvidence: [evidence]
        )
    }
}
