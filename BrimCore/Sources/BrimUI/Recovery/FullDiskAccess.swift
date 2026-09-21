import Foundation
import AppKit
import BrimCore

/// Whether Brim can read the parts of the disk it needs.
///
/// macOS gives no API to ask "do I have Full Disk Access", and none to grant
/// it — only the user can, in System Settings. So this probes by attempting
/// the thing that actually fails without it, and offers to open the right
/// settings pane.
public enum FullDiskAccess {

    /// Probes by opening the user's Trash for event monitoring, which is the
    /// operation Brim genuinely needs and which returns EPERM without access.
    /// A read-only open, immediately closed — nothing is modified.
    ///
    /// The probe itself lives in BrimCore, because scanning needs the same
    /// answer as the UI: a leftover Brim can see but cannot remove has to
    /// say why.
    public static func isGranted(
        probing url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    ) -> Bool {
        FullDiskAccessProbe.isGranted(probing: url)
    }

    /// Opens System Settings at Privacy & Security › Full Disk Access.
    /// Granting it there restarts Brim, which macOS requires for the change
    /// to take effect.
    public static func openSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        guard let url = URL(string: pane) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Publishes Full Disk Access state for the UI, re-probing whenever the app
/// comes back to the foreground — which is when the user returns from having
/// changed it in System Settings.
@MainActor
public final class FullDiskAccessModel: ObservableObject {
    @Published public private(set) var isGranted: Bool

    /// Set once the user has been sent to System Settings, so the prompt can
    /// explain that Brim must be reopened rather than repeating itself.
    @Published public private(set) var hasRequested = false

    private var observer: NSObjectProtocol?
    private let probe: @Sendable () -> Bool

    public init(probe: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted() }) {
        self.probe = probe
        self.isGranted = probe()
    }

    deinit {
        // Observer is torn down in stopObserving(); NSWorkspace drops it on
        // deallocation and a nonisolated deinit cannot touch actor state.
    }

    public func startObserving() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard NSRunningApplication.current.isActive else { return }
            MainActor.assumeIsolated { self?.recheck() }
        }
    }

    public func stopObserving() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    public func recheck() {
        isGranted = probe()
    }

    public func requestAccess() {
        hasRequested = true
        FullDiskAccess.openSettings()
    }
}
