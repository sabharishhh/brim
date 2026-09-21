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
        @unknown default: state = .unavailable("macOS gave an answer Brim does not know.")
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
    public func uninstall() async {
        connection?.invalidate()
        connection = nil
        try? await service.unregister()
        refresh()
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

    private func openConnection() -> NSXPCConnection {
        if let connection { return connection }
        let fresh = NSXPCConnection(machServiceName: BrimJobHelper.machServiceName, options: .privileged)
        fresh.remoteObjectInterface = NSXPCInterface(with: BrimJobHelperProtocol.self)
        // The daemon checks the app, and the app checks the daemon. Either
        // side accepting the other on trust is how a root service ends up
        // talking to something that replaced it.
        fresh.setCodeSigningRequirement(BrimJobHelper.daemonRequirement())
        fresh.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        fresh.resume()
        connection = fresh
        return fresh
    }
}
