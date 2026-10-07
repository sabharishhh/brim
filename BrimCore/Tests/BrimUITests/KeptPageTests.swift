import BrimCore
import BrimProtocol
import BrimUI
import Foundation
import Testing

/// Pages open on what the last launch found, and act on none of it until
/// this launch has looked again.
@MainActor struct KeptPageTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("brim-pages-\(UUID().uuidString)")
    }

    private func orphan(_ name: String, bytes: Int64 = 100) -> Leftover {
        Leftover(url: URL(fileURLWithPath: "/fixture/" + name), size: bytes, category: .orphaned,
                 potentialOwner: Identity(bundleID: "org.example." + name, name: name), evidence: "Fixture record")
    }

    private func kept(_ items: [Leftover], in folder: URL) async -> PageCache<[Leftover]> {
        let cache = PageCache<[Leftover]>("remnants", version: 1, folder: folder)
        cache.save(items)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while cache.load() == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return cache
    }

    /// A footprint is a claim about the disk now. Rows read back from the
    /// last launch are shown, so the page is never empty, and none of them
    /// can be ticked or sent to a review until a scan has confirmed them.
    @Test func `kept remnants are shown and cannot be removed until a scan confirms them`() async {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = await kept([orphan("Gone")], in: folder)
        let model = LeftoversModel(cache: cache)
        #expect(model.orphanedGroups.count == 1)
        #expect(model.isProvisional)
        #expect(model.checkedAt != nil)
        let group = model.orphanedGroups[0]
        model.toggle(group)
        model.selectAllRemovableOrphans()
        #expect(model.selectedItems.isEmpty)
        #expect(model.removalIntent(for: group, requesterIdentity: "test") == nil)

        await model.load(service: KeptReads(leftovers: [orphan("Gone")]))
        #expect(!model.isProvisional)
        #expect(model.removalIntent(for: model.orphanedGroups[0], requesterIdentity: "test") != nil)
    }

    /// A format change is a miss, never a misread.
    @Test func `a kept page from another version is ignored`() async {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = await kept([orphan("Gone")], in: folder)
        #expect(PageCache<[Leftover]>("remnants", version: 2, folder: folder).load() == nil)
    }

    /// Space ran its own remnants scan for its estimate, a second
    /// four-second walk whenever it opened after Remnants had finished.
    @Test func `the Space estimate comes from Remnants and follows it without scanning again`() async {
        let service = KeptReads(leftovers: [orphan("Gone", bytes: 300)])
        let remnants = LeftoversModel()
        let space = StorageModel(leftovers: remnants)
        await remnants.load(service: service)
        await space.load(service: service)
        #expect(await service.leftoverCalls == 1)
        #expect(space.brimCanClear == 300)
        #expect(space.brimCanClearCount == 1)
        remnants.forget(paths: ["/fixture/Gone"])
        #expect(space.brimCanClear == 0)
        #expect(await service.leftoverCalls == 1)
    }
}

private actor KeptReads: BrimServiceProtocol {
    let items: [Leftover]
    private(set) var leftoverCalls = 0

    init(leftovers: [Leftover]) {
        items = leftovers
    }

    func leftovers() async throws -> [Leftover] {
        leftoverCalls += 1
        return items
    }

    func volumes() -> [VolumeAccount] {
        [VolumeAccount(name: "Fixture", url: URL(fileURLWithPath: "/"), capacity: 1000,
                       freeRightNow: 200, reclaimableByTheSystem: 100, snapshots: [], isRemovable: false)]
    }

    func installedApplications() async throws -> [InstalledApplication] {
        []
    }

    func recoverableItems() async throws -> [RecoverableItem] {
        []
    }

    func history() async throws -> [Plan] {
        []
    }

    func inspect(identity _: Identity) async throws -> Footprint {
        throw Unused.unused
    }

    func plan(intent _: PlanIntent) async throws -> Plan {
        throw Unused.unused
    }

    func requestApproval(planId _: UUID, requesterIdentity _: String) async throws -> ApprovalRequestReceipt {
        throw Unused.unused
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {
        throw Unused.unused
    }

    func verify(planId _: UUID) async throws -> VerificationResult {
        throw Unused.unused
    }

    func undo(planId _: UUID) async throws {
        throw Unused.unused
    }
}

private enum Unused: Error { case unused }
