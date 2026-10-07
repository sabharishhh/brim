import Foundation
import AppKit
import BrimCore

/// Whether Brim can read the parts of the disk it needs.
///
/// macOS gives no API to ask "do I have Full Disk Access", and none to grant
/// it: only the person can, in System Settings. So this probes by attempting
/// the thing that actually fails without it, and offers to open the right
/// settings pane.
public enum FullDiskAccess {

    /// Probes by opening the user's Trash for event monitoring, which is the
    /// operation Brim genuinely needs and which returns EPERM without access.
    /// A read-only open, immediately closed. Nothing is modified.
    ///
    /// The probe itself lives in BrimCore, because scanning needs the same
    /// answer as the UI: a leftover Brim can see but cannot remove has to
    /// say why.
    public static func isGranted(
        probing url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    ) -> Bool {
        FullDiskAccessProbe.isGranted(probing: url)
    }

    /// Opens System Settings at Privacy & Security › Full Disk Access, and
    /// remembers that it did and from where.
    ///
    /// Switching Brim on there makes macOS offer to quit and reopen it. Brim
    /// used to come back on whatever page window restoration chose, with the
    /// Settings window gone, so the person had to find their way back to
    /// what they were doing. The request is remembered so the next launch
    /// can return them to it, and so a Brim still running can offer to
    /// reopen itself when the person chose Later.
    public static func openSettings(from origin: Origin = .window) {
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSinceReferenceDate, forKey: requestedKey)
        defaults.set(origin.rawValue, forKey: originKey)
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        guard let url = URL(string: pane) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Where the person was when Brim sent them to System Settings.
    public enum Origin: String, Sendable {
        case window, settings
    }

    /// When Brim last sent the person to System Settings, as seconds since
    /// the reference date. Views read it with `@AppStorage` so a request
    /// made anywhere updates every place that offers to reopen.
    public static let requestedKey = "access.requestedAt"
    public static let originKey = "access.requestedFrom"

    /// A request counts for half an hour. Past that, a launch is an
    /// ordinary launch and not the second half of granting access.
    public static func isRecent(_ requestedAt: Double, now: Date = Date()) -> Bool {
        requestedAt > 0 && now.timeIntervalSinceReferenceDate - requestedAt < 30 * 60
    }

    /// The pending request, if one was made recently.
    public static var pendingRequest: Origin? {
        let defaults = UserDefaults.standard
        guard isRecent(defaults.double(forKey: requestedKey)) else { return nil }
        return Origin(rawValue: defaults.string(forKey: originKey) ?? "") ?? .window
    }

    /// Forgets the request, once access is on or a relaunch did not bring it.
    public static func clearRequest() {
        UserDefaults.standard.removeObject(forKey: requestedKey)
        UserDefaults.standard.removeObject(forKey: originKey)
    }
}

/// Publishes Full Disk Access state for the UI, re-probing whenever the app
/// comes back to the foreground, which is when the person returns from having
/// changed it in System Settings.
@MainActor
public final class FullDiskAccessModel: ObservableObject {
    @Published public private(set) var isGranted: Bool

    /// Set once the user has been sent to System Settings, so the prompt can
    /// offer to reopen Brim rather than repeating itself. Read from the
    /// remembered request, so it holds across the models that ask.
    @Published public private(set) var hasRequested = FullDiskAccess.pendingRequest != nil

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
        let granted = probe()
        if granted {
            FullDiskAccess.clearRequest()
            hasRequested = false
        } else {
            hasRequested = FullDiskAccess.pendingRequest != nil
        }
        if granted != isGranted {
            isGranted = granted
        }
    }

    public func requestAccess(from origin: FullDiskAccess.Origin = .window) {
        hasRequested = true
        FullDiskAccess.openSettings(from: origin)
    }
}
