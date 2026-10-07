import BrimCore
import BrimProtocol
import Combine
import Foundation

/// Backs the Developer section.
@MainActor
public final class DeveloperModel: ObservableObject {
    @Published public private(set) var caches: [DeveloperCache] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var scanWasCancelled = false
    /// A scan has finished since the folders it covers last changed. Until
    /// then an empty list is not a measured zero.
    @Published public private(set) var hasLoaded = false
    @Published public var ageFilter: DeveloperAgeFilter = .all
    @Published public private(set) var excludedFolders: Set<URL> = []

    public var visibleCaches: [DeveloperCache] {
        caches.filter { ageFilter.includes($0) }
    }

    public var selectedOutsideFilter: Int {
        Set(selectedCaches.map(\.id)).subtracting(visibleCaches.map(\.id)).count
    }

    public func exclude(_ folder: URL) {
        cancelScan()
        excludedFolders.insert(folder.standardizedFileURL)
        caches.removeAll { isExcluded($0.url) }
        selection = selection.intersection(eligibleCaches.map(\.id))
        hasLoaded = false
    }

    public func resetExclusions() {
        cancelScan()
        excludedFolders = []
        hasLoaded = false
    }

    /// The rows on screen are the last launch's, kept on disk, and this
    /// launch's scan has not reported yet. Shown, never selectable.
    @Published public private(set) var isProvisional = false
    private let cache: PageCache<[DeveloperCache]>?

    public init(cache: PageCache<[DeveloperCache]>? = nil) {
        self.cache = cache
        guard let kept = cache?.load() else { return }
        caches = kept.value
        isProvisional = true
    }

    public var totalBytes: Int64 {
        DeveloperCache.estimatedTotal(of: caches)
    }

    public static func sizeSummary(_ caches: [DeveloperCache]) -> String {
        guard !caches.isEmpty else { return ByteText.short(0) }
        let measured = caches.filter {
            $0.sizeMeasurement.map { $0.state == .complete || $0.state == .partial } ?? true
        }
        guard !measured.isEmpty else {
            return caches.allSatisfy { $0.sizeMeasurement?.state == .pending } ? "Measuring" : "Size unavailable"
        }
        let bytes = DeveloperCache.estimatedTotal(of: measured)
        let partial = caches.contains {
            $0.sizeMeasurement.map { $0.state != .complete } ?? false
        }
        if partial && bytes == 0 {
            return "Partial sizes"
        }
        return partial ? "Partial estimate: " + ByteText.short(bytes) : ByteText.short(bytes) + " estimated"
    }

    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        guard !hasLoaded, !isScanning else { return }
        await load(service: service)
    }

    private var loadTask: Task<Void, Never>?
    private var loadGeneration = UUID()

    /// The section owns one scan, with an explicit cancellation boundary when
    /// its view disappears. A late result cannot replace a newer scan.
    public func load(service: any BrimServiceProtocol) async {
        guard !Task.isCancelled else { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let generation = UUID()
        loadGeneration = generation
        let task = Task { await self.performLoad(service: service, generation: generation) }
        loadTask = task
        defer {
            if loadGeneration == generation {
                loadTask = nil
            }
        }
        await task.value
    }

    public func cancelScan() {
        guard loadTask != nil else { return }
        loadGeneration = UUID()
        loadTask?.cancel()
        loadTask = nil
        isScanning = false
        scanWasCancelled = true
        hasLoaded = false
        selection = selection.intersection(eligibleCaches.map(\.id))
    }

    private func performLoad(service: any BrimServiceProtocol, generation: UUID) async {
        guard !Task.isCancelled, loadGeneration == generation, !isScanning else { return }
        isScanning = true
        scanWasCancelled = false
        defer {
            if loadGeneration == generation {
                isScanning = false
            }
        }
        let updates = await service.developerCacheUpdates(excluding: Array(excludedFolders))
        for await fetched in updates {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            // Discovery and measurement update the same identity. Selection is
            // always manual; a newly discovered row never inherits Select All.
            caches = fetched.filter { !isExcluded($0.url) }
            isProvisional = false
            // An absent project may not have arrived yet. A present row with
            // changed eligibility must leave the selection immediately.
            selection.subtract(caches.filter { !$0.cost.isBrimRemovable }.map(\.id))
        }
        guard !Task.isCancelled, loadGeneration == generation else { return }
        selection = selection.intersection(eligibleCaches.map(\.id))
        hasLoaded = true
        isProvisional = false
        cache?.save(caches)
    }

    /// Artifacts chosen manually. Current eligibility is checked whenever
    /// selection changes or a removal intent is created.
    @Published public var selection: Set<String> = []

    public func isSelected(_ cache: DeveloperCache) -> Bool {
        selection.contains(cache.id) && cache.cost.isBrimRemovable && !isExcluded(cache.url)
    }

    public func toggle(_ cache: DeveloperCache) {
        guard !isProvisional, let current = caches.first(where: { $0.id == cache.id }),
              current.cost.isBrimRemovable, !isExcluded(current.url) else { return }
        if selection.contains(cache.id) {
            selection.remove(cache.id)
        } else {
            selection.insert(cache.id)
        }
    }

    /// A section's Select All and Deselect All. Only what Brim may clear is
    /// ever selected, whatever the list passed in holds.
    public func setSelected(_ selected: Bool, _ caches: [DeveloperCache]) {
        guard !isProvisional else { return }
        let ids = caches.filter { $0.cost.isBrimRemovable && !isExcluded($0.url) }.map(\.id)
        if selected {
            selection.formUnion(ids)
        } else {
            selection.subtract(ids)
        }
    }

    public func clearSelection() {
        selection = []
    }

    private var eligibleCaches: [DeveloperCache] {
        caches.filter { $0.cost.isBrimRemovable && !isExcluded($0.url) }
    }

    private var selectedCaches: [DeveloperCache] {
        eligibleCaches.filter { selection.contains($0.id) }
    }

    public var selectedCount: Int {
        selectedCaches.count
    }

    public var selectedBytes: Int64 {
        DeveloperCache.estimatedTotal(of: selectedCaches)
    }

    public var canRemove: Bool {
        !selectedCaches.isEmpty
    }

    private func isExcluded(_ url: URL) -> Bool {
        excludedFolders.contains { ArtifactSizer.rootsOverlap(url, $0) }
    }

    /// Removal covers currently eligible artifacts only.
    ///
    /// The guard is here as well as in `toggle` because this is the last
    /// point before a plan exists, and T-5.7 turns on nothing in class
    /// three ever reaching one.
    public func removalIntent(requesterIdentity: String) -> PlanIntent? {
        guard !isProvisional else { return nil }
        let targets = selectedCaches.map(\.url)
        guard !targets.isEmpty else { return nil }
        return PlanIntent(
            type: .uninstall,
            subjectIdentity: Identity(bundleID: nil, name: "Build caches"),
            requesterKind: "ui",
            requesterIdentity: requesterIdentity,
            specificTargets: targets,
            excludedFolders: excludedFolders.isEmpty ? nil : excludedFolders.sorted { $0.path < $1.path }
        )
    }
}
