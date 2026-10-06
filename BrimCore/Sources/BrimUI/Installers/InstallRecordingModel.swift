import AppKit
import BrimCore
import BrimProtocol
import Combine
import Foundation

/// An install being recorded, shared by Home, the menu bar and the sheet
/// that shows what it found.
///
/// The first snapshot is kept by the service, so a recording outlives
/// Brim: reopening finds it still open and says since when.
@MainActor
public final class InstallRecordingModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case finishing(since: Date)
        case found(InstallRecordingResult)
    }

    @Published public private(set) var phase: Phase = .idle
    /// What went wrong last, shown once. A failure never ends a recording
    /// that is open: the first snapshot is still kept.
    @Published public var problem: String?
    private var service: (any BrimServiceProtocol)?
    private var hasLoaded = false

    // MARK: Installs Brim performs

    /// What Brim waits for to finish a recording it started itself.
    public enum Waiting: Equatable, Sendable {
        /// The app it installed: its first run ends when it quits.
        case app(bundleID: String, name: String, url: URL)
        /// Apple's Installer, running a package.
        case installer(name: String)
    }

    @Published public private(set) var waiting: Waiting?
    /// An installer to offer to move to the Trash, once what it installed
    /// is in place.
    @Published public var installerToTrash: URL?
    /// A recording kept without asking, because everything it found was
    /// linked to the install. Shown once, as a note.
    @Published public var keptQuietly: InstallRecording?
    /// Something to say once, such as an install that put nothing down.
    @Published public var notice: String?
    /// A package whose install is still running in Installer.
    private var pendingPackage: URL?
    private var observer: NSObjectProtocol?

    public init() {}

    public var since: Date? {
        switch phase {
        case let .recording(since), let .finishing(since): since
        default: nil
        }
    }

    public var isRecording: Bool {
        since != nil
    }

    /// Picks up a recording left open when Brim last quit.
    public func load(service: any BrimServiceProtocol) async {
        self.service = service
        guard !hasLoaded else { return }
        hasLoaded = true
        if phase == .idle, let since = await service.activeInstallRecording() {
            phase = .recording(since: since)
        }
    }

    public func start(service: any BrimServiceProtocol) async {
        self.service = service
        guard phase == .idle else { return }
        phase = .starting
        do {
            phase = try await .recording(since: service.beginInstallRecording())
        } catch {
            phase = .idle
            problem = error.localizedDescription
        }
    }

    public func finish() async {
        guard let service, let since else { return }
        phase = .finishing(since: since)
        do {
            phase = try await .found(service.finishInstallRecording())
        } catch {
            phase = .recording(since: since)
            problem = error.localizedDescription
        }
    }

    /// Ends the recording without keeping anything.
    public func cancel() async {
        await service?.cancelInstallRecording()
        phase = .idle
        stopWaiting()
        pendingPackage = nil
    }

    /// Goes back to recording, for a result shown too early: the app was
    /// not opened yet, or its setup had not finished.
    public func keepRecording() {
        guard case let .found(result) = phase else { return }
        phase = .recording(since: result.startedAt)
    }

    /// Keeps the chosen apps and items. Returns whether it was saved.
    @discardableResult
    public func keep(_ result: InstallRecordingResult, apps: Set<String>, items: Set<String>) async -> Bool {
        await keptRecording(result, apps: apps, items: items) != nil
    }

    private func keptRecording(
        _ result: InstallRecordingResult, apps: Set<String>, items: Set<String>
    ) async -> InstallRecording? {
        guard let service else { return nil }
        let chosenApps = result.apps.filter { apps.contains($0.id) }
        guard !chosenApps.isEmpty else { return nil }
        let chosenItems = (result.linked + result.unclaimed).filter { item in
            items.contains(item.id) && (item.app == nil || apps.contains(item.app ?? ""))
        }
        let recording = InstallRecording(startedAt: result.startedAt, endedAt: result.endedAt, apps: chosenApps,
                                         items: chosenItems)
        do {
            try await service.keepInstallRecording(recording)
            phase = .idle
            stopWaiting()
            // A package's file is offered to the Trash only once what it
            // installed is known to be there.
            if let package = pendingPackage {
                installerToTrash = package
                pendingPackage = nil
            }
            return recording
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    // MARK: - Installing

    public enum InstallOutcome: Equatable, Sendable {
        case installed(URL)
        case openedInstaller
        case failed(String)
    }

    /// Installs what the person looked inside, recording around it.
    ///
    /// An app is copied into Applications by Brim; a package opens in
    /// Apple's Installer, which runs its developer's scripts, not Brim. The
    /// recording finishes on its own when the installed app first quits, or
    /// when Installer does, while Brim is open. A recording the person
    /// started is kept running and used.
    public func install(_ preview: InstallerPreview, service: any BrimServiceProtocol) async -> InstallOutcome {
        self.service = service
        let startedHere = !isRecording
        if startedHere {
            await start(service: service)
            guard isRecording else { return .failed(problem ?? "Brim could not start recording.") }
        }
        if preview.kind == .package {
            let installer = URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app")
            do {
                _ = try await NSWorkspace.shared.open([preview.source], withApplicationAt: installer,
                                                      configuration: NSWorkspace.OpenConfiguration())
            } catch {
                if startedHere {
                    await cancel()
                }
                return .failed("Installer could not open the package.")
            }
            pendingPackage = preview.source
            wait(for: .installer(name: preview.name))
            return .openedInstaller
        }
        guard let item = Self.installable(preview), let app = item.apps.first else {
            if startedHere {
                await cancel()
            }
            return .failed("There is no app in it to install.")
        }
        do {
            let url = try await service.installApplication(
                from: preview.source, identifier: app.identifier, trusted: item.signature.verdict.isTrusted
            )
            if let identifier = app.identifier {
                wait(for: .app(bundleID: identifier, name: app.name, url: url))
            }
            return .installed(url)
        } catch {
            if startedHere {
                await cancel()
            }
            return .failed(error.localizedDescription)
        }
    }

    /// What Brim can install from a preview: a package, through Installer,
    /// or an app on its own or alone at the top of a disk image when it is
    /// not installed already. Updating an installed app is the Updates
    /// page's, which checks the new copy against the one installed.
    public static func installable(_ preview: InstallerPreview) -> InstallerPreview? {
        let item: InstallerPreview? = switch preview.kind {
        case .application: preview
        case .diskImage: preview.contents.count == 1 && preview.contents[0].kind == .application
            ? preview.contents[0] : nil
        case .package: preview
        }
        guard let item else { return nil }
        if item.kind == .application, item.apps.first?.isInstalled == true {
            return nil
        }
        return item
    }

    private func wait(for target: Waiting) {
        stopWaiting()
        waiting = target
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let quit = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            MainActor.assumeIsolated {
                self?.quit(quit)
            }
        }
    }

    private func quit(_ bundleID: String?) {
        guard let waiting, let bundleID else { return }
        let finished = switch waiting {
        case let .app(identifier, _, _): bundleID.lowercased() == identifier.lowercased()
        case .installer: bundleID == "com.apple.installer"
        }
        guard finished else { return }
        stopWaiting()
        Task { await finishOnItsOwn() }
    }

    private func stopWaiting() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        waiting = nil
    }

    /// Keeps what is linked without asking; asks only when something
    /// appeared that nothing links to the install.
    func finishOnItsOwn() async {
        await finish()
        guard case let .found(result) = phase else { return }
        if result.apps.isEmpty {
            await cancel()
            notice = "Nothing was installed, so nothing was recorded."
            return
        }
        guard result.unclaimed.isEmpty else { return }
        let apps = Set(result.apps.filter { !$0.wasUpdated }.map(\.id))
        keptQuietly = await keptRecording(result, apps: apps.isEmpty ? Set(result.apps.map(\.id)) : apps,
                                          items: Set(result.linked.map(\.id)))
    }
}

public extension InstallerSignature.Verdict {
    /// Gatekeeper accepted it, so an install must find it still accepted.
    var isTrusted: Bool {
        switch self {
        case .notarized, .apple, .appStore: true
        default: false
        }
    }
}
