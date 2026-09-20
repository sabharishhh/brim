import Foundation

/// Watches the user's Trash and reports when its contents change, so the app
/// reflects the user emptying it rather than waiting to be relaunched.
///
/// Two mechanisms, because one is not always available. Opening `~/.Trash`
/// for event monitoring needs Full Disk Access, and without it the open fails
/// with EPERM — so a kqueue source is used when permission allows, and
/// otherwise the watcher falls back to polling. Statting a *known path inside*
/// the Trash is allowed even when opening the directory is not, which is what
/// makes the fallback work at all.
///
/// The fallback runs only while the app is active, so a backgrounded Brim is
/// not waking the CPU to look at a directory nobody is watching.
public actor TrashWatcher {
    public typealias ChangeHandler = @Sendable () async -> Void

    /// How this watcher is currently learning about changes. Exposed so the
    /// app can report degraded behaviour instead of silently going stale.
    public enum Mode: Equatable, Sendable {
        /// Kernel events: immediate, no wakeups when nothing happens.
        case events
        /// Permission for event monitoring was refused; checking periodically.
        case polling(interval: Duration)
    }

    private let url: URL
    private let coalescingWindow: Duration
    private let pollInterval: Duration

    private var source: DispatchSourceFileSystemObject?
    private var pendingNotification: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var handler: ChangeHandler?
    private var isActive = true

    public private(set) var mode: Mode = .events

    public init(
        url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"),
        coalescingWindow: Duration = .milliseconds(300),
        pollInterval: Duration = .seconds(2)
    ) {
        self.url = url
        self.coalescingWindow = coalescingWindow
        self.pollInterval = pollInterval
    }

    deinit {
        source?.cancel()
        pendingNotification?.cancel()
        pollTask?.cancel()
    }

    /// Begins watching. Calling it again replaces the handler and restarts,
    /// so a view reappearing cannot stack duplicate watchers.
    public func start(onChange: @escaping ChangeHandler) {
        stop()
        handler = onChange

        if startEventSource() {
            mode = .events
        } else {
            mode = .polling(interval: pollInterval)
            startPolling()
        }
    }

    public func stop() {
        source?.cancel()
        source = nil
        pendingNotification?.cancel()
        pendingNotification = nil
        pollTask?.cancel()
        pollTask = nil
        handler = nil
    }

    /// Polling is suspended while the app is inactive and resumed — with an
    /// immediate check — when it becomes active again, so returning to Brim
    /// after emptying the Trash in Finder is always up to date.
    public func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active

        guard case .polling = mode, handler != nil else { return }
        if active {
            startPolling()
            Task { await fire() }
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    /// - Returns: whether kernel-event monitoring could be established.
    private func startEventSource() -> Bool {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.noteChange() }
        }
        // Closing the descriptor here, and only here, is what keeps
        // start/stop cycles from leaking file descriptors.
        source.setCancelHandler { [fd] in close(fd) }

        self.source = source
        source.resume()
        return true
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled else { return }
                await self.fire()
            }
        }
    }

    /// Coalesce a burst of events into one notification once things settle.
    private func noteChange() {
        pendingNotification?.cancel()
        pendingNotification = Task { [coalescingWindow] in
            try? await Task.sleep(for: coalescingWindow)
            guard !Task.isCancelled else { return }
            await self.fire()
        }
    }

    private func fire() async {
        pendingNotification = nil
        await handler?()
    }
}
