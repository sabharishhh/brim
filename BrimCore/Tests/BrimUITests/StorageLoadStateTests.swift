import BrimCore
import BrimProtocol
import BrimUI
import Foundation
import Testing

@MainActor struct StorageLoadStateTests {
    /// The volume request finished, but the tuple await kept Home's free-space
    /// card waiting for the entire leftovers scan.
    @Test func volumesPublishWhileTheFirstEstimateIsStillPending() async {
        let service = StorageReads()
        let model = StorageModel()
        let load = Task { await model.load(service: service) }
        await waitUntil { await service.leftoverCalls == 1 && model.startupVolume != nil }
        #expect(model.startupVolume?.freeRightNow == 200)
        #expect(model.isLoading)
        #expect(!model.hasEstimate)
        #expect(model.brimCanClearFigure == "…")
        #expect(!model.estimateUnavailable)
        let items = [leftover("Removed", bytes: 100), leftover("Unknown", bytes: 400, orphaned: false)]
        await service.finish(.success(items))
        await load.value
        #expect(model.hasEstimate)
        #expect(!model.isLoading)
        #expect(model.brimCanClear == 100)
        #expect(model.brimCanClearCount == 1)
    }

    @Test func aFailedEstimateKeepsPublishedVolumesAndReportsTheGap() async {
        let service = StorageReads()
        let model = StorageModel()
        let load = Task { await model.load(service: service) }
        await waitUntil { await service.leftoverCalls == 1 && model.startupVolume != nil }
        #expect(!model.hasEstimate)
        await service.finish(.failure(StorageReadFailure.unreadable))
        await load.value
        #expect(model.startupVolume?.freeRightNow == 200)
        #expect(model.hasEstimate)
        #expect(model.estimateUnavailable)
        #expect(model.brimCanClearFigure == "Size unavailable")
        #expect(!model.isLoading)
    }

    @Test func aRefreshKeepsThePreviousEstimateWhileNewVolumesArrive() async {
        let service = StorageReads()
        let model = StorageModel()
        let first = Task { await model.load(service: service) }
        await waitUntil { await service.leftoverCalls == 1 }
        await service.finish(.success([leftover("Removed", bytes: 100)]))
        await first.value
        await service.setFreeBytes(500)
        let refresh = Task { await model.load(service: service) }
        await waitUntil { await service.leftoverCalls == 2 && model.startupVolume?.freeRightNow == 500 }
        #expect(model.isLoading)
        #expect(model.hasEstimate)
        #expect(model.brimCanClear == 100)
        await service.finish(.success([]))
        await refresh.value
        #expect(model.brimCanClear == 0)
        #expect(model.brimCanClearCount == 0)
        #expect(!model.estimateUnavailable)
        #expect(!model.isLoading)
    }

    /// A scan can return a removed app's location without being able to size it.
    /// Space must carry that limitation instead of turning its zero into Empty.
    @Test(arguments: [Int64(0), Int64(100)])
    func incompleteMeasurementsKeepTheEstimatePartial(bytes: Int64) async {
        let service = StorageReads()
        let model = StorageModel()
        let load = Task { await model.load(service: service) }
        await waitUntil { await service.leftoverCalls == 1 }
        let item = Leftover(url: URL(fileURLWithPath: "/fixture/Removed"), size: bytes,
                            category: .orphaned, sizeIsKnown: false)
        await service.finish(.success([item]))
        await load.value
        #expect(model.hasEstimate)
        #expect(model.estimateUnavailable)
        #expect(model.brimCanClear == bytes)
        let figure = bytes > 0 ? "At least " + ByteText.short(bytes) : "Size unavailable"
        #expect(model.brimCanClearFigure == figure)
    }

    private func leftover(_ name: String, bytes: Int64, orphaned: Bool = true) -> Leftover {
        Leftover(url: URL(fileURLWithPath: "/fixture/" + name), size: bytes,
                 category: orphaned ? .orphaned : .unclaimed,
                 potentialOwner: Identity(bundleID: "org.example." + name, name: name), evidence: "Fixture record")
    }

    private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while await !predicate(), ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await predicate())
    }
}

private actor StorageReads: BrimServiceProtocol {
    private var freeBytes: Int64 = 200
    private var continuation: CheckedContinuation<[Leftover], any Error>?
    private(set) var leftoverCalls = 0

    func volumes() -> [VolumeAccount] {
        [VolumeAccount(name: "Fixture", url: URL(fileURLWithPath: "/"), capacity: 1000,
                       freeRightNow: freeBytes, reclaimableByTheSystem: 100, snapshots: [], isRemovable: false)]
    }

    func leftovers() async throws -> [Leftover] {
        leftoverCalls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ result: Result<[Leftover], any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func setFreeBytes(_ bytes: Int64) {
        freeBytes = bytes
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
        throw StorageReadFailure.unused
    }

    func plan(intent _: PlanIntent) async throws -> Plan {
        throw StorageReadFailure.unused
    }

    func requestApproval(planId _: UUID, requesterIdentity _: String) async throws -> ApprovalRequestReceipt {
        throw StorageReadFailure.unused
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {
        throw StorageReadFailure.unused
    }

    func verify(planId _: UUID) async throws -> VerificationResult {
        throw StorageReadFailure.unused
    }

    func undo(planId _: UUID) async throws {
        throw StorageReadFailure.unused
    }
}

private enum StorageReadFailure: Error { case unreadable, unused }
