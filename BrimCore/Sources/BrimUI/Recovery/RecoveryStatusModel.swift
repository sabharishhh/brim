import Foundation
import Combine
import AppKit
import BrimCore
import BrimProtocol

/// Live view of what is still recoverable from the Trash.
///
/// The app must not go stale when the user empties the Trash in Finder, so
/// the state is refreshed from four triggers: when the view appears, whenever
/// the watcher reports a change, when Brim itself removes something, and when
/// the app becomes active again. Everything is recomputed from the service
/// rather than adjusted incrementally, so an external change can never leave
/// a drifting local tally.
@MainActor
public final class RecoveryStatusModel: ObservableObject {
    @Published public private(set) var items: [RecoverableItem] = []
    @Published public private(set) var isRefreshing = false
    /// True when the watcher could not get kernel events and is polling, so
    /// the UI can explain the delay rather than appear broken.
    @Published public private(set) var isPolling = false

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var isEmpty: Bool { items.isEmpty }

    private let watcher: TrashWatcher
    private var service: (any BrimServiceProtocol)?
    private var refreshTask: Task<Void, Never>?
    private var activationObservers: [NSObjectProtocol] = []
    private var started = false

    public init(watcher: TrashWatcher = TrashWatcher()) {
        self.watcher = watcher
    }

    deinit {
        refreshTask?.cancel()
        // Observers are removed in stop(); a nonisolated deinit cannot touch
        // main-actor state, and NSWorkspace drops them when we deallocate.
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
        let mode = await watcher.mode
        if case .polling = mode { isPolling = true }

        observeActivation()
    }

    public func stop() async {
        started = false
        refreshTask?.cancel()
        refreshTask = nil
        await watcher.stop()

        let center = NSWorkspace.shared.notificationCenter
        for observer in activationObservers { center.removeObserver(observer) }
        activationObservers = []
    }

    /// Call after Brim removes something, so the indicator updates without
    /// waiting for the watcher to notice.
    public func refreshNow() {
        Task { await refresh() }
    }

    /// Coming back from Finder is the moment a user is most likely to have
    /// just emptied the Trash, so treat it as a refresh point and let the
    /// watcher stand down while we are in the background.
    private func observeActivation() {
        let center = NSWorkspace.shared.notificationCenter
        let watcher = self.watcher

        activationObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard NSRunningApplication.current.isActive else { return }
            Task { await watcher.setActive(true) }
            self?.refreshNow()
        })

        activationObservers.append(center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: .main
        ) { _ in
            guard !NSRunningApplication.current.isActive else { return }
            Task { await watcher.setActive(false) }
        })
    }

    private func refresh() async {
        guard let service else { return }

        // One refresh at a time; a burst of changes should not fan out into
        // overlapping scans of the ledger.
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
