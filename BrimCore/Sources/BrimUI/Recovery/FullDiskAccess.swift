import Foundation
import AppKit
import BrimCore

/// Whether Brim can read what it needs. macOS has no API to ask or grant
/// Full Disk Access, so this probes and offers the settings pane.
public enum FullDiskAccess {

    /// Opens the user's Trash for event monitoring, which fails with EPERM
    /// without access; read-only and closed at once. The probe is in BrimCore,
    /// because scanning needs the same answer.
    public static func isGranted(
        probing url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    ) -> Bool {
        FullDiskAccessProbe.isGranted(probing: url)
    }

    /// Opens Privacy & Security › Full Disk Access and remembers when and from
    /// where, so the relaunch macOS offers returns the person to what they were
    /// doing, and a Brim still running can offer to reopen itself.
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

    /// When Brim last sent the person to System Settings. Read with
    /// `@AppStorage`, so every page offering to reopen updates together.
    public static let requestedKey = "access.requestedAt"
    public static let originKey = "access.requestedFrom"

    /// A request counts for half an hour; after that a launch is ordinary.
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

/// Publishes Full Disk Access state, probing again whenever the app becomes
/// active, which is when the person returns from System Settings.
@MainActor
public final class FullDiskAccessModel: ObservableObject {
    @Published public private(set) var isGranted: Bool

    /// Set once the person has been sent to System Settings, so the prompt can
    /// offer to reopen Brim instead of repeating itself.
    @Published public private(set) var hasRequested = FullDiskAccess.pendingRequest != nil

    private var observer: NSObjectProtocol?
    private let probe: @Sendable () -> Bool

    public init(probe: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted() }) {
        self.probe = probe
        self.isGranted = probe()
    }

    deinit {
        // Removed in `stopObserving()`; a nonisolated deinit cannot touch actor
        // state.
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
