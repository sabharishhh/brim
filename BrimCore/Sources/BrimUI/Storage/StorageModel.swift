import BrimCore
import BrimProtocol
import Combine
import Foundation

/// Backs Space. Holds two things never added together: what the volumes
/// report, which is measured, and what Brim could clear, which is a claim
/// Brim must stand behind.
@MainActor
public final class StorageModel: ObservableObject {
    @Published public private(set) var volumes: [VolumeAccount] = []
    @Published public private(set) var isLoading = false

    /// What Brim found and could remove, from the Remnants scan, not estimated.
    @Published public private(set) var brimCanClear: Int64 = 0
    @Published public private(set) var brimCanClearCount = 0

    @Published public private(set) var estimateUnavailable = false
    /// The first volume result can arrive before the estimate; a pending
    /// estimate is not an empty scan.
    @Published public private(set) var hasEstimate = false

    /// Remnants, whose result the estimate comes from, so Space never runs a
    /// second scan.
    private weak var leftovers: LeftoversModel?
    private var estimateWatch: AnyCancellable?

    public init(leftovers: LeftoversModel? = nil) {
        self.leftovers = leftovers
        guard let leftovers else { return }
        estimateWatch = leftovers.$orphaned
            .combineLatest(leftovers.$checkedAt, leftovers.$errorMessage)
            .sink { [weak self] orphaned, checkedAt, failure in
                guard checkedAt != nil || failure != nil else { return }
                self?.estimate(from: failure == nil ? orphaned : nil)
            }
    }

    public var startupVolume: VolumeAccount? {
        volumes.first { $0.url.path == "/" } ?? volumes.first
    }

    /// Failed and incomplete measurements have no exact size to display.
    public var brimCanClearFigure: String {
        guard hasEstimate else { return "…" }
        if estimateUnavailable {
            return brimCanClear > 0 ? "At least " + ByteText.short(brimCanClear) : "Size unavailable"
        }
        return ByteText.short(brimCanClear)
    }

    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        guard volumes.isEmpty, !isLoading else { return }
        await load(service: service)
    }

    private var loadTask: Task<Void, Never>?

    /// The section owns its scan. Navigation can cancel a view's waiter without
    /// discarding the result or leaving a second view waiting on an empty model.
    public func load(service: any BrimServiceProtocol) async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await self.performLoad(service: service) }
        loadTask = task
        defer { loadTask = nil }
        await task.value
    }

    private func performLoad(service: any BrimServiceProtocol) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let leftovers {
            // The estimate follows Remnants' result as it changes; this only
            // makes sure there is one.
            async let scan: Void = leftovers.loadIfNeeded(service: service)
            let newVolumes = await service.volumes()
            guard !Task.isCancelled else { return }
            volumes = newVolumes
            await scan
            return
        }
        async let accounts = service.volumes()
        async let found = try? service.leftovers()
        let newVolumes = await accounts
        guard !Task.isCancelled else { return }
        volumes = newVolumes
        let leftovers = await found
        guard !Task.isCancelled else { return }
        estimate(from: leftovers?.filter { $0.category == .orphaned })
    }

    /// Free space alone: a few milliseconds, so it can follow the disk while
    /// Space or Home is shown.
    public func readVolumes(service: any BrimServiceProtocol) async {
        let newVolumes = await service.volumes()
        if newVolumes != volumes {
            volumes = newVolumes
        }
    }

    /// Only what a record ties to a removed app counts, as on Home and Remnants;
    /// unnamed items are listed but never added to a figure. Nil is a failed
    /// scan.
    private func estimate(from orphaned: [Leftover]?) {
        estimateUnavailable = orphaned == nil || (orphaned ?? []).contains { $0.sizeIsKnown == false }
        brimCanClear = (orphaned ?? []).reduce(0) { $0 + $1.size }
        brimCanClearCount = (orphaned ?? []).groupedByOwner().count
        hasEstimate = true
    }
}
