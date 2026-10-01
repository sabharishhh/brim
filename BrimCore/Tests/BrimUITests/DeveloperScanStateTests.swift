import BrimCore
import BrimProtocol
import BrimUI
import Foundation
import Testing

@MainActor struct DeveloperScanStateTests {
    @Test func streamingUpdatesPreserveOnlyManualSelection() async throws {
        let service = DeveloperStreamService()
        let model = DeveloperModel()
        let first = cache("first", size: .pending)
        let second = cache("second", size: .pending)
        let load = Task { await model.load(service: service) }
        try await waitUntil { await service.streamCount == 1 }
        await service.publish([first])
        try await waitUntil { model.caches.count == 1 }
        model.selectRegenerable()
        await service.publish([
            first.measured(using: ArtifactSize(logicalBytes: 10, allocatedBytes: 10, state: .complete)),
            second
        ])
        try await waitUntil { model.caches.count == 2 }
        #expect(model.selection == [first.id])
        #expect(model.caches[0].sizeBytes == 10)
        #expect(DeveloperModel.sizeSummary(model.caches).hasPrefix("Partial estimate:"))
        await service.finish()
        await load.value
        #expect(!model.isScanning)
    }

    @Test(arguments: [DeveloperCache.Cost.configured, .refetched])
    func aRescanRemovesNewlyIneligibleRowsFromSelectionAndTray(_ cost: DeveloperCache.Cost) async throws {
        let service = DeveloperStreamService()
        let model = DeveloperModel()
        let spent = cache("update")
        let other = cache("other")
        let first = Task { await model.load(service: service) }
        try await waitUntil { await service.streamCount == 1 }
        await service.publish([spent, other])
        await service.finish()
        await first.value
        model.selectRegenerable()
        #expect(model.selectedCount == 2 && model.selectedBytes == 200)
        let rescan = Task { await model.load(service: service) }
        try await waitUntil { await service.streamCount == 2 }
        await service.publish([other], stream: 1)
        try await waitUntil { model.caches.count == 1 }
        #expect(model.selection.contains(spent.id))
        #expect(model.selectedCount == 1 && model.selectedBytes == 100)
        let waiting = DeveloperCache(name: "Waiting", tool: spent.tool, url: spent.url,
                                     sizeBytes: 50000, cost: cost, explanation: "Leave with its tool")
        await service.publish([waiting, other], stream: 1)
        try await waitUntil { model.caches.count == 2 }
        #expect(model.selection == [other.id])
        #expect(model.selectedCount == 1 && model.selectedBytes == 100)
        #expect(!model.isSelected(spent) && !model.isSelected(waiting))
        model.toggle(spent)
        #expect(model.selection == [other.id])
        model.selection = [spent.id, other.id]
        #expect(model.selectedCount == 1 && model.selectedBytes == 100)
        #expect(model.removalIntent(requesterIdentity: "test")?.explicitTargets == [other.url])
        await service.finish(stream: 1)
        await rescan.value
        #expect(model.selection == [other.id])
    }

    @Test func cancelledOrReplacedScanCannotPublishAnOldSnapshot() async throws {
        let service = DeveloperStreamService()
        let model = DeveloperModel()
        let oldLoad = Task { await model.load(service: service) }
        try await waitUntil { await service.streamCount == 1 }
        model.cancelScan()
        #expect(model.scanWasCancelled)
        let newLoad = Task { await model.load(service: service) }
        try await waitUntil { await service.streamCount == 2 }
        await service.publish([cache("new")], stream: 1)
        try await waitUntil { model.caches.first?.tool == "new" }
        await service.publish([cache("old")], stream: 0)
        await service.finish(stream: 0)
        await oldLoad.value
        #expect(model.caches.first?.tool == "new")
        #expect(model.isScanning)
        await service.finish(stream: 1)
        await newLoad.value
        #expect(!model.isScanning)
    }

    @Test func excludedFoldersClearSelectionAndAgeNeverBecomesOwnership() async throws {
        let service = DeveloperStreamService()
        let model = DeveloperModel()
        let recent = cache("recent", lastBuilt: Date())
        let old = cache("old", lastBuilt: Date().addingTimeInterval(-100 * 24 * 60 * 60))
        let stateful = DeveloperCache(name: "Archives", tool: "Xcode", url: URL(fileURLWithPath: "/dev/Archives"),
                                      sizeBytes: 1, cost: .configured, explanation: "Keep shipped archives",
                                      lastBuilt: Date().addingTimeInterval(-200 * 24 * 60 * 60))
        let load = Task { await model.load(service: service) }
        try await waitUntil { await service.streamCount == 1 }
        await service.publish([recent, old, stateful])
        await service.finish()
        await load.value
        model.toggle(recent)
        model.ageFilter = .olderThan90Days
        #expect(model.selectedOutsideFilter == 1)
        model.selectRegenerable()
        #expect(model.selection == [recent.id, old.id])
        #expect(!model.selection.contains(stateful.id))
        model.exclude(URL(fileURLWithPath: "/dev/recent"))
        #expect(model.selection == [old.id])
        #expect(model.excludedFolders.count == 1)
    }

    @Test func cancelledLoadLeavesTheModelReadyAndResumesAnInterruptedRescan() async throws {
        let service = DeveloperStreamService()
        let model = DeveloperModel()
        let cancelled = Task { await model.load(service: service) }
        cancelled.cancel()
        await cancelled.value
        #expect(!model.isScanning)
        let first = Task { await model.load(service: service) }
        try await waitUntil { await service.streamCount == 1 }
        await service.publish([cache("previous")])
        await service.finish()
        await first.value
        model.selectRegenerable()
        let interrupted = Task { await model.load(service: service) }
        try await waitUntil { await service.streamCount == 2 }
        await service.publish([], stream: 1)
        try await waitUntil { model.caches.isEmpty }
        model.cancelScan()
        await interrupted.value
        #expect(model.selection.isEmpty)
        #expect(!model.canRemove)
        let resumed = Task { await model.loadIfNeeded(service: service) }
        try await waitUntil { await service.streamCount == 3 }
        await service.finish(stream: 2)
        await resumed.value
        #expect(!model.isScanning)
    }

    @Test func excludingAChildRejectsStaleParentRowsAndTravelsWithTheIntent() async throws {
        let service = DeveloperStreamService()
        let model = DeveloperModel()
        let parent = cache("parent")
        let other = cache("other")
        let first = Task { await model.load(service: service) }
        try await waitUntil { await service.streamCount == 1 }
        await service.publish([parent, other])
        await service.finish()
        await first.value
        model.selectRegenerable()
        let excluded = parent.url.appendingPathComponent("local-copy")
        model.exclude(excluded)
        model.toggle(parent)
        #expect(model.selection == [other.id])
        #expect(model.caches == [other])
        let rescan = Task { await model.load(service: service) }
        try await waitUntil { await service.streamCount == 2 }
        await service.publish([parent, other], stream: 1)
        await service.finish(stream: 1)
        await rescan.value
        #expect(model.caches == [other])
        let intent = try #require(model.removalIntent(requesterIdentity: "test"))
        #expect(intent.explicitTargets == [other.url])
        #expect(intent.excludedFolders == [excluded])
        model.selection = [parent.id]
        #expect(!model.canRemove)
        #expect(model.removalIntent(requesterIdentity: "test") == nil)
    }

    @Test func unmeasuredAndPartiallyReadSizesAreNeverPresentedAsEmpty() {
        #expect(DeveloperModel
            .sizeSummary([cache("unknown", size: ArtifactSize(state: .unknown))]) == "Size unavailable")
        #expect(DeveloperModel.sizeSummary([cache("partial", size: ArtifactSize(state: .partial))]) == "Partial sizes")
        #expect(DeveloperModel.sizeSummary([cache("pending", size: .pending)]) == "Measuring")
    }

    @Test func helperQuarantineAndToolRunsDoNotPretendToBePermanentFileDeletion() {
        let helper = removal(kind: .trashPathPrivileged)
        let native = removal(kind: .delegateToolCleanup)
        #expect(helper.unavailableReason?.contains("restore is unavailable") == true)
        #expect(!helper.spoken.contains("Deleted permanently"))
        #expect(native.unavailableReason == "Run by the tool; cannot be undone")
    }

    private func cache(_ tool: String, size: ArtifactSize? = nil, lastBuilt: Date? = nil) -> DeveloperCache {
        DeveloperCache(name: "Build output", tool: tool, url: URL(fileURLWithPath: "/dev/\(tool)"),
                       sizeBytes: size?.allocatedBytes ?? 100, cost: .rebuilt, explanation: "Build again",
                       lastBuilt: lastBuilt, sizeMeasurement: size, artifactClassification: .rebuildableOutput)
    }

    private func removal(kind: StepKind) -> RemovalRecord {
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "1", osVersion: "test",
                        intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: nil, name: "Test"),
                                           requesterKind: "ui", requesterIdentity: "test"),
                        steps: [Step(index: 0, kind: kind, target: "/test", targetFingerprint: nil, tier: .B,
                                     evidence: "Test", expectedBytes: 1, capability: .ok, reversible: false,
                                     costOfError: .low)], excludedItems: [], expectedTotalBytes: 1)
        return RemovalRecord(plan: plan, recoverable: nil)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while await !predicate(), ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await predicate())
    }
}

private actor DeveloperStreamService: BrimServiceProtocol {
    private var streams: [AsyncStream<[DeveloperCache]>.Continuation] = []
    var streamCount: Int {
        streams.count
    }

    func developerCacheUpdates(excluding _: [URL]) async -> AsyncStream<[DeveloperCache]> {
        let (stream, continuation) = AsyncStream<[DeveloperCache]>.makeStream()
        streams.append(continuation)
        return stream
    }

    func publish(_ caches: [DeveloperCache], stream: Int = 0) {
        streams[stream].yield(caches)
    }

    func finish(stream: Int = 0) {
        streams[stream].finish()
    }

    func inspect(identity _: Identity) async throws -> Footprint {
        throw UnusedCall.notImplemented
    }

    func plan(intent _: PlanIntent) async throws -> Plan {
        throw UnusedCall.notImplemented
    }

    func explain(planId _: UUID) async throws -> String {
        throw UnusedCall.notImplemented
    }

    func requestApproval(planId _: UUID, requesterIdentity _: String) async throws -> ApprovalRequestReceipt {
        throw UnusedCall.notImplemented
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {
        throw UnusedCall.notImplemented
    }

    func verify(planId _: UUID) async throws -> VerificationResult {
        throw UnusedCall.notImplemented
    }

    func history() async throws -> [Plan] {
        []
    }

    func undo(planId _: UUID) async throws {
        throw UnusedCall.notImplemented
    }

    func installedApplications() async throws -> [InstalledApplication] {
        []
    }

    func leftovers() async throws -> [Leftover] {
        []
    }

    func recoverableItems() async throws -> [RecoverableItem] {
        []
    }
}

private enum UnusedCall: Error { case notImplemented }
