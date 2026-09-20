import Foundation
import Combine
import BrimCore
import BrimProtocol

/// Live view of what is still recoverable from the Trash.
///
/// The app must not go stale when the user empties the Trash in Finder, so the
/// state is refreshed from three triggers: when the view appears, whenever the
/// Trash changes underneath us, and immediately after Brim itself removes
/// something. Everything is recomputed from the service rather than adjusted
/// incrementally, so an external change can never leave a drifting local tally.
@MainActor
public final class RecoveryStatusModel: ObservableObject {
    @Published public private(set) var items: [RecoverableItem] = []
    @Published public private(set) var isRefreshing = false

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var isEmpty: Bool { items.isEmpty }

    private let watcher: TrashWatcher
    private var service: (any BrimServiceProtocol)?
    private var refreshTask: Task<Void, Never>?
    private var started = false

    public init(watcher: TrashWatcher = TrashWatcher()) {
        self.watcher = watcher
    }

    deinit {
        refreshTask?.cancel()
    }

    /// Loads the current state and begins watching. Safe to call repeatedly:
    /// a view that reappears refreshes rather than starting a second watcher.
    public func start(service: any BrimServiceProtocol) async {
        self.service = service
        await refresh()

        guard !started else { return }
        started = true

        await watcher.start { [weak self] in
            await self?.refresh()
        }
    }

    public func stop() async {
        started = false
        refreshTask?.cancel()
        refreshTask = nil
        await watcher.stop()
    }

    /// Call after Brim removes something, so the indicator updates without
    /// waiting for the file-system event to make its way back to us.
    public func refreshNow() {
        Task { await refresh() }
    }

    private func refresh() async {
        guard let service else { return }

        // One refresh at a time; a burst of Trash events should not fan out
        // into overlapping scans of the ledger.
        refreshTask?.cancel()
        let task = Task { [service] in
            await MainActor.run { self.isRefreshing = true }
            defer { Task { @MainActor in self.isRefreshing = false } }

            let fetched = (try? await service.recoverableItems()) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run { self.items = fetched }
        }
        refreshTask = task
        await task.value
    }
}
