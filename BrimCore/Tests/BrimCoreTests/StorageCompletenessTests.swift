import BrimCore
import Foundation
import Testing

struct StorageCompletenessTests {
    @Test func anExpiredAggregateCannotPublishACompleteFootprint() async throws {
        let fixture = try AccountingFixture()
        let folder = try fixture.put("output/file", bytes: 4096).deletingLastPathComponent()
        let projected = fixture.projected(folder, bytes: 4096)
        let account = await StorageAccountant().account(for: projected.items, budget: ScanBudget(total: 0))
        let published = account.applying(to: projected)
        #expect(account.measurement.state == .unknown)
        #expect(published.completeness.isComplete == false)
        #expect(published.completeness.timedOut == [folder.path])
        #expect(published.logicalSizeBytes == 0)
        #expect(published.reclaimableSizeBytes == nil)
        #expect(published.snapshotPinnedBytes == nil)
        #expect(published.items == projected.items)
    }

    @Test func anEntryLimitedAggregateKeepsItsMeasuredFloorAndTheSearchGaps() async throws {
        let fixture = try AccountingFixture()
        let folder = try fixture.put("output/first", bytes: 4096).deletingLastPathComponent()
        try fixture.put("output/second", bytes: 4096)
        let searchGap = ScanCompleteness(unreadable: ["/search/refused"])
        let resolverGap = ScanCompleteness(timedOut: ["/bundle/resolver"])
        let projected = fixture.projected(folder, bytes: 8192, completeness: searchGap)
        let account = await StorageAccountant().account(for: projected.items, maximumEntries: 1)
        let published = account.applying(to: projected, additionalCompleteness: resolverGap)
        #expect(account.measurement.state == .partial)
        #expect(published.logicalSizeBytes == 4096)
        #expect(published.completeness.unreadable == searchGap.unreadable)
        #expect(Set(published.completeness.timedOut) == [folder.path, "/bundle/resolver"])
        #expect(published.reclaimableSizeBytes == nil)
        #expect(published.snapshotPinnedBytes == nil)
    }

    @Test func anUnreadableAggregateKeepsEarlierCompleteMeasurementsIncomplete() async throws {
        let fixture = try AccountingFixture()
        let visible = try fixture.put("output/visible", bytes: 4096)
        let refused = try fixture.put("output/refused/hidden", bytes: 4096).deletingLastPathComponent()
        let projected = fixture.projected(visible.deletingLastPathComponent(), bytes: 8192)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: refused.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: refused.path) }
        let account = await StorageAccountant().account(for: projected.items)
        let published = account.applying(to: projected)
        #expect(account.measurement.state == .partial)
        #expect(published.logicalSizeBytes == 4096)
        #expect(published.completeness.unreadable == [refused.path])
        #expect(published.completeness.isComplete == false)
    }

    @Test func aggregateAccountingStillCountsOverlappingHardlinkedContentOnce() async throws {
        let fixture = try AccountingFixture()
        let file = try fixture.put("output/file", bytes: 4096)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.linkItem(at: file, to: folder.appendingPathComponent("hardlink"))
        let items = [fixture.projected(folder, bytes: 8192).items[0], fixture.projected(file, bytes: 4096).items[0]]
        let projected = Footprint(identity: Identity(name: "Fixture"), items: items)
        let account = await StorageAccountant().account(for: items)
        let published = account.applying(to: projected)
        #expect(account.measurement.state == .complete)
        #expect(published.logicalSizeBytes == 4096)
        #expect(published.completeness.isComplete)
        #expect(published.reclaimableSizeBytes == nil)
        #expect(published.snapshotPinnedBytes == nil)
    }
}

private final class AccountingFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("accounting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult func put(_ path: String, bytes: Int) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: file)
        return file
    }

    func projected(_ url: URL, bytes: Int64, completeness: ScanCompleteness = .complete) -> Footprint {
        Footprint(identity: Identity(name: "Fixture"), items: [FootprintItem(
            evidence: Evidence(url: url, tier: .A, mechanism: "Fixture", humanSentence: "Measured output."),
            sizeBytes: bytes, capability: .ok,
            sizeMeasurement: ArtifactSize(logicalBytes: bytes, state: .complete)
        )], completeness: completeness)
    }
}
