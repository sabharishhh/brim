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

    @Published public private(set) var state: State = .notInstalled

    private let log = Logger(subsystem: "com.sabharishhh.brim", category: "helper")
    private var connection: NSXPCConnection?

    public init() { refresh() }

    private var service: SMAppService {
        SMAppService.daemon(plistName: "\(BrimJobHelper.machServiceName).plist")
    }

    public func refresh() {
        switch service.status {
        case .notRegistered: state = .notInstalled
        case .enabled: state = .ready
        case .requiresApproval: state = .waitingForApproval
        case .notFound: state = .unavailable("The daemon is missing from this copy of Brim.")
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
