import Foundation

/// Watches the user's Trash and reports when its contents change, so the app
/// can react to the user emptying it rather than waiting until it is next
/// relaunched.
///
/// Uses a kqueue file-system source on the directory rather than polling: the
/// kernel wakes us only when something actually changes. Bursts are coalesced,
/// because emptying the Trash produces one event per item removed and the
/// interesting thing is the settled state, not each step of it.
public actor TrashWatcher {
    public typealias ChangeHandler = @Sendable () async -> Void

    private let url: URL
    private let coalescingWindow: Duration

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var pendingNotification: Task<Void, Never>?
    private var handler: ChangeHandler?

    public init(
        url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"),
        coalescingWindow: Duration = .milliseconds(300)
    ) {
        self.url = url
        self.coalescingWindow = coalescingWindow
    }

    deinit {
        // The source owns the descriptor via its cancel handler; if we never
        // started, close directly.
        if let source {
            source.cancel()
        } else if descriptor >= 0 {
            close(descriptor)
        }
        pendingNotification?.cancel()
    }

    /// Begins watching. Calling it again replaces the handler and restarts the
    /// source, so a view re-appearing cannot stack duplicate watchers.
    public func start(onChange: @escaping ChangeHandler) {
        stop()
        handler = onChange

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // No Trash directory to watch (or no permission). The caller still
            // gets its initial load; it simply will not be woken by changes.
            return
        }
        descriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.noteChange() }
        }

        // Closing the descriptor here, and only here, is what keeps start/stop
        // cycles from leaking file descriptors.
        source.setCancelHandler { [fd] in
            close(fd)
        }

        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
        pendingNotification?.cancel()
        pendingNotification = nil
        handler = nil
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
