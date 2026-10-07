import AppKit
import BrimCore
import BrimProtocol
import Combine
import Foundation

/// The recording around an install Brim makes. Nobody starts or finishes
/// one by hand: installing from the preview starts it, and the installed
/// app quitting, or Installer quitting, finishes it.
///
/// The first snapshot is kept by the service, so a recording outlives
/// Brim: the next launch finds it still open and finishes it.
@MainActor
public final class InstallRecordingModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case finishing(since: Date)
    }

    @Published public private(set) var phase: Phase = .idle
    /// What went wrong last, shown once. A failure never ends a recording
    /// that is open: the first snapshot is still kept.
    @Published public var problem: String?
    private var service: (any BrimServiceProtocol)?
    private var hasLoaded = false

    // MARK: Installs Brim performs

    /// What Brim waits for to finish a recording it started itself.
    enum Waiting: Equatable, Sendable {
        /// The app it installed: its first run ends when it quits.
        case app(bundleID: String)
        /// Apple's Installer, running a package.
        case installer
    }

    private var waiting: Waiting?
    /// A recording just kept. The window reads Apps again on it, since a
    /// package's app arrived through Installer rather than through Brim.
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
        // A recording an earlier launch left open has nothing waiting on it
        // any more, and nobody finishes one by hand: Brim finishes it now,
        // keeping what links to an install or saying nothing was installed.
        if phase == .idle, let since = await service.activeInstallRecording() {
            phase = .recording(since: since)
            await finishOnItsOwn()
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

    /// Ends the recording without keeping anything.
    public func cancel() async {
        await service?.cancelInstallRecording()
        phase = .idle
        stopWaiting()
        pendingPackage = nil
    }

    private func keep(
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
                Self.discardInstaller(package)
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
    public func install(
        _ preview: InstallerPreview, service: any BrimServiceProtocol,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async -> InstallOutcome {
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
            wait(for: .installer)
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
                from: preview.source, identifier: app.identifier, trusted: item.signature.verdict.isTrusted,
                progress: progress
            )
            if let identifier = app.identifier {
                wait(for: .app(bundleID: identifier))
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
        case let .app(identifier): bundleID.lowercased() == identifier.lowercased()
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

    /// Takes the second snapshot and keeps what links to the install.
    ///
    /// Anything else that appeared meanwhile is left out rather than asked
    /// about: nobody started this recording, so nobody should be asked to
    /// judge it. It used to publish what it found first, which showed the
    /// old review sheet, with its Keep Recording button, for as long as
    /// saving took, and left it up when saving failed.
    func finishOnItsOwn() async {
        guard let service, let since else { return }
        phase = .finishing(since: since)
        let result: InstallRecordingResult
        do {
            result = try await service.finishInstallRecording()
        } catch {
            phase = .recording(since: since)
            problem = error.localizedDescription
            return
        }
        if result.apps.isEmpty {
            await cancel()
            notice = "Nothing was installed, so nothing was recorded"
            return
        }
        // An app that only updated itself while recording is not what was
        // installed, unless nothing new appeared at all.
        let fresh = Set(result.apps.filter { !$0.wasUpdated }.map(\.id))
        let kept = await keep(result, apps: fresh.isEmpty ? Set(result.apps.map(\.id)) : fresh,
                              items: Set(result.linked.map(\.id)))
        if let kept {
            keptQuietly = kept
        } else {
            // Saving failed. The recording stays open, as any failure leaves
            // it, and the next launch finishes it again.
            phase = .recording(since: since)
        }
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

public extension InstallRecordingModel {
    /// Moves an installer to the Trash once what it installed is in place,
    /// without asking: almost nobody keeps one, and the Trash can put it
    /// back. Only from the person's own folders, never from Applications
    /// or another volume.
    static func discardInstaller(_ url: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(home), !path.hasPrefix(home + "Applications/"),
              FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
