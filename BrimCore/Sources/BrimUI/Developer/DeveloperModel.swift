import Foundation
import Combine
import BrimCore
import BrimProtocol

/// Backs the Developer section.
@MainActor
public final class DeveloperModel: ObservableObject {
    @Published public private(set) var caches: [DeveloperCache] = []
    @Published public private(set) var isScanning = false

    public init() {}

    public var totalBytes: Int64 { caches.reduce(0) { $0 + $1.sizeBytes } }

    /// What comes back on its own, which is the figure worth acting on.
    public var recoverableBytes: Int64 {
        caches.filter { $0.cost != .configured }.reduce(0) { $0 + $1.sizeBytes }
    }

    public func loadIfNeeded(service: any BrimServiceProtocol) async {
        guard caches.isEmpty, !isScanning else { return }
        await load(service: service)
    }

    public func load(service: any BrimServiceProtocol) async {
        isScanning = true
        defer { isScanning = false }
        caches = await service.developerCaches()
        selection = selection.intersection(caches.map(\.id))
    }

    /// Caches chosen for removal. Only the regenerable class can be here:
    /// `toggle` refuses the rest, so nothing downstream has to re-check.
    @Published public var selection: Set<String> = []

    public func isSelected(_ cache: DeveloperCache) -> Bool { selection.contains(cache.id) }

    public func toggle(_ cache: DeveloperCache) {
        guard cache.cost.isBrimRemovable else { return }
        if selection.contains(cache.id) { selection.remove(cache.id) }
        else { selection.insert(cache.id) }
    }

    public func selectRegenerable() {
        for cache in caches where cache.cost.isBrimRemovable { selection.insert(cache.id) }
    }

    public func clearSelection() { selection = [] }

    public var selectedBytes: Int64 {
        caches.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
    }

    public var canRemove: Bool { !selection.isEmpty }

    /// Removal covers the regenerable class only.
    ///
    /// The guard is here as well as in `toggle` because this is the last
    /// point before a plan exists, and T-5.7 turns on nothing in class
    /// three ever reaching one.
    public func removalIntent(requesterIdentity: String) -> PlanIntent? {
        let targets = caches
            .filter { selection.contains($0.id) && $0.cost.isBrimRemovable }
            .map(\.url)
        guard !targets.isEmpty else { return nil }
        return PlanIntent(
            type: .uninstall,
            subjectIdentity: Identity(bundleID: nil, name: "Build caches"),
            requesterKind: "ui",
            requesterIdentity: requesterIdentity,
            specificTargets: targets
        )
    }
}
