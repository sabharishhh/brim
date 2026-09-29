import Foundation
import Combine
import BrimCore
import BrimProtocol

/// Backs the Storage section.
///
/// Holds two things that must not be added together: what the volumes
/// report about themselves, and what Brim believes it could clear. The
/// first is measured, the second is a claim Brim has to stand behind, and
/// a single "you could free 12 GB" number made of both would be neither.
@MainActor
public final class StorageModel: ObservableObject {

    @Published public private(set) var volumes: [VolumeAccount] = []
    @Published public private(set) var isLoading = false

    /// What Brim has actually found and could remove, taken from the
    /// leftovers scan rather than estimated.
    @Published public private(set) var brimCanClear: Int64 = 0
    @Published public private(set) var brimCanClearCount = 0

    @Published public private(set) var estimateUnavailable = false

    public init() {}

    public var startupVolume: VolumeAccount? {
        volumes.first { $0.url.path == "/" } ?? volumes.first
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
        async let accounts = service.volumes()
        async let found = try? service.leftovers()
        let (newVolumes, leftovers) = await (accounts, found)
        guard !Task.isCancelled else { return }
        volumes = newVolumes
        estimateUnavailable = leftovers == nil
        // Only what a record ties to a removed app counts, in apps, the
        // same way Home and Leftovers count. Something nobody can be
        // named for is shown in the list and never added to a figure.
        let orphaned = (leftovers ?? []).filter { $0.category == .orphaned }
        brimCanClear = orphaned.reduce(0) { $0 + $1.size }
        brimCanClearCount = orphaned.groupedByOwner().count
    }
}
