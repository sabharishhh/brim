import Foundation
import ServiceManagement
import os

/// Talking to the privileged daemon, and installing it if it is not there.
///
/// Installation is one approval, in System Settings, given once. macOS
/// then runs the daemon as root on demand. There is no password prompt per
/// removal, and nothing runs at login: the daemon starts when Brim asks
/// and stops when it is done.
@MainActor
public final class PrivilegedHelperClient: ObservableObject {

    public enum State: Equatable, Sendable {
        /// Brim has not asked macOS yet, and on purpose.
        ///
        /// Asking is not free and it is not private. Reading
        /// `SMAppService.status` makes `smd` open the bundle, build a
        /// background-item configuration out of the daemon plist inside it,
        /// and ask Background Task Management for that item's disposition.
        /// On a Mac where the daemon has never been registered, BTM has no
        /// record of it, and being asked about an item it has never seen is
        /// what makes macOS announce a new background item. With no record
        /// there is no stored name either, so the notification reads
        /// "(null) can run in the background".
        ///
        /// Brim was doing that three times on every launch without anybody
        /// having asked for the helper, which is precisely the kind of
        /// unexplained background registration this product exists to find.
        case notAsked
        /// Never installed, or the user removed it.
        case notInstalled
        /// Installed, but the person has not allowed it yet in System
        /// Settings. macOS will not start it until they do.
        case waitingForApproval
        case ready
        /// Installed, and the person switched it off on purpose.
        case disabledByUser
        /// Registered, but it is an older Brim's daemon. Talking to it
        /// would mean trusting rules this version has since changed.
        case stale(installed: String)
        case unavailable(String)

        public var canRemove: Bool { self == .ready }
    }

    @Published public private(set) var state: State = .notAsked

    private let log = Logger(subsystem: "com.sabharishhh.brim", category: "helper")
    private var connection: NSXPCConnection?

    /// Deliberately does nothing. See `State.notAsked`.
    public init() {}

    private var service: SMAppService {
        SMAppService.daemon(plistName: "\(BrimJobHelper.machServiceName).plist")
    }

    /// Whether this copy of Brim actually ships the daemon it would register.
    ///
    /// A local question with a local answer, and it tells `notFound` apart
    /// from a missing file. `SMAppService` answers `notFound` when Background
    /// Task Management holds no record for the item, which is the ordinary
    /// state of a daemon nobody has installed. Reporting that as "the daemon
    /// is missing from this copy of Brim" was wrong on every Mac where the
    /// helper had simply never been set up, which is all of them until
    /// somebody sets it up.
    private var daemonIsInTheBundle: Bool {
        guard let plists = Bundle.main.url(
            forResource: nil, withExtension: nil, subdirectory: "Contents/Library/LaunchDaemons"
        ) ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons") as URL?
        else { return false }
        let plist = plists.appendingPathComponent("\(BrimJobHelper.machServiceName).plist")
        return FileManager.default.fileExists(atPath: plist.path)
    }

    /// Reads the status once, and only where somebody is about to act on it.
    ///
    /// Call this from a view that shows helper state or from a flow that is
    /// about to need the daemon. Do not call it at launch.
    public func refreshIfNeeded() {
        guard state == .notAsked else { return }
        refresh()
    }

    /// Reads the status, whatever it was before. For the points where the
    /// answer can genuinely have changed: after installing, after the person
    /// comes back from System Settings, and before handing the daemon work.
    public func refresh() {
        switch service.status {
        case .notRegistered: state = .notInstalled
        case .enabled: state = .ready
        case .requiresApproval: state = .waitingForApproval
        case .notFound:
            state = daemonIsInTheBundle
                ? .notInstalled
                : .unavailable("This copy of Brim does not include the helper.")
        @unknown default:
            // A status this build of Brim predates. Say what it means for the
            // person rather than that Brim did not recognise the value.
            state = .unavailable("This version of macOS reports the helper differently. "
                                 + "Updating Brim should settle it.")
        }
    }

    /// Registers the daemon. macOS shows the approval in Login Items, and
    /// nothing runs until the person says yes.
    public func install() {
        do {
            try service.register()
            log.info("registered the privileged daemon")
        } catch {
            // Already registered is not a failure worth reporting as one.
            log.error("could not register: \(error.localizedDescription)")
            state = .unavailable(error.localizedDescription)
            return
        }
        refresh()
    }

    /// Takes the daemon away again. Removing Brim should not leave a root
    /// daemon behind, and neither should changing your mind.
    ///
    /// Two halves, in this order. The daemon clears the quarantine while
    /// it is still running, because that directory is root owned and
    /// nothing else can touch it. Then macOS is told to forget the
    /// daemon. Doing it the other way round leaves the folder behind for
    /// good.
    public func uninstall() async -> String? {
        // Ask macOS here whatever the cached state says. This is the one
        // moment the answer has to be current: `state` starts at `notAsked`
        // now, and skipping the daemon's own cleanup because Brim had not
        // looked yet would leave the root-owned quarantine folder on the
        // disk for good, which is the exact failure this product exists to
        // point at in other people's software.
        refresh()

        var complaint: String?
        if state == .ready {
            complaint = await askDaemonToCleanUp()
        }
        connection?.invalidate()
        connection = nil
        try? await service.unregister()
        refresh()
        return complaint
    }

    private func askDaemonToCleanUp() async -> String? {
        await withCheckedContinuation { continuation in
            let connection = openConnection()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(returning: error.localizedDescription)
            } as? BrimJobHelperProtocol
            guard let proxy else {
                return continuation.resume(returning: "The helper did not answer.")
            }
            proxy.uninstallSelf { complaint in continuation.resume(returning: complaint) }
        }
    }

    /// Asks the running daemon what version it is, and refuses to use one
    /// this copy of Brim does not recognise.
    ///
    /// `SMAppService` keeps a daemon registered across an application
    /// update, so the root process answering can be the one an older Brim
    /// installed. Its rules about what is safe to remove are that older
    /// version's rules. The comment on `BrimJobHelper.version` has always
    /// said the app should replace a stale copy rather than talk to it;
    /// this is the part that was missing.
    public func verifyVersion() async {
        guard state == .ready else { return }
        let installed: String? = await withCheckedContinuation { continuation in
            let connection = openConnection()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                continuation.resume(returning: nil)
            } as? BrimJobHelperProtocol
            guard let proxy else { return continuation.resume(returning: nil) }
            proxy.version { continuation.resume(returning: $0) }
        }

        guard let installed else { return }
        guard installed != BrimJobHelper.version else { return }

        log.info("replacing a daemon from an older Brim (\(installed))")
        connection?.invalidate()
        connection = nil
        try? await service.unregister()
        install()
        if state == .ready {
            // Registration succeeded, but macOS may still be running the
            // old binary until it next starts. Reported rather than
            // assumed away.
            state = .stale(installed: installed)
        }
    }

    public func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - The one thing it does

    /// Asks the daemon to set aside a job file. The reply is nil when it
    /// worked, otherwise the daemon's own sentence explaining why not.
    public func removeDefunctJob(domain: PrivilegedJobRemoval.Domain, name: String) async -> String? {
        guard state == .ready else {
            return "Brim's helper is not set up, so it cannot touch anything outside your own Library."
        }
        return await withCheckedContinuation { continuation in
            let connection = openConnection()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(returning: error.localizedDescription)
            } as? BrimJobHelperProtocol

            guard let proxy else {
                return continuation.resume(returning: "The helper did not answer.")
            }
            proxy.removeDefunctJob(domain: domain.rawValue, name: name) { refusal in
                continuation.resume(returning: refusal)
            }
        }
    }

    /// Asks the daemon to forget an installer receipt. Nil when it
    /// worked, otherwise the daemon's own sentence explaining why not.
    public func forgetReceipt(packageID: String) async -> String? {
        guard state == .ready else {
            return "Brim's helper is not set up, so the installer's record of this package "
                 + "stays where it is."
        }
        return await withCheckedContinuation { continuation in
            let connection = openConnection()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(returning: error.localizedDescription)
            } as? BrimJobHelperProtocol

            guard let proxy else {
                return continuation.resume(returning: "The helper did not answer.")
            }
            proxy.forgetReceipt(packageID: packageID) { refusal in
                continuation.resume(returning: refusal)
            }
        }
    }

    private func openConnection() -> NSXPCConnection {
        if let connection { return connection }
        let fresh = NSXPCConnection(machServiceName: BrimJobHelper.machServiceName, options: .privileged)
        fresh.remoteObjectInterface = NSXPCInterface(with: BrimJobHelperProtocol.self)
        // The daemon checks the app, and the app checks the daemon. Either
        // side accepting the other on trust is how a root service ends up
        // talking to something that replaced it.
        // Compiled first: `setCodeSigningRequirement` raises on a string
        // it cannot parse rather than returning a failure.
        let requirement = BrimJobHelper.daemonRequirement()
        if BrimJobHelper.isWellFormed(requirement) {
            fresh.setCodeSigningRequirement(requirement)
        } else {
            log.error("the daemon requirement will not compile; not connecting")
            fresh.invalidate()
            return fresh
        }
        fresh.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        fresh.resume()
        connection = fresh
        return fresh
    }
}
