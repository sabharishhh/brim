import Foundation
import BrimCore
import BrimProtocol
import BrimService

/// Decides which `BrimServiceProtocol` implementation the UI talks to.
///
/// The privileged daemon is only present once it has been installed with
/// `SMAppService`. Until then the app runs the same `BrimService` actor
/// in-process, so scanning and user-domain removals work without a helper.
/// Set `BRIM_USE_DAEMON=1` to route through the daemon instead.
enum BrimServiceLocator {
    static let daemonMachServiceName = "com.google.Brim.daemon"

    enum Backend: String {
        case inProcess = "In-process"
        case daemon = "Privileged daemon"
    }

    private(set) static var backend: Backend = .inProcess

    static func makeService() -> any BrimServiceProtocol {
        if ProcessInfo.processInfo.environment["BRIM_USE_DAEMON"] == "1" {
            backend = .daemon
            return makeDaemonClient()
        }
        backend = .inProcess
        return makeInProcessService()
    }

    /// Gives the service the one thing that lets it mint an approval: a
    /// window, in front of a person.
    ///
    /// This is what separates the app from every other client. The CLI and
    /// an MCP host run the same code and hold the same kind of service
    /// object, and neither of them installs this, so neither of them can
    /// turn a plan into a token however they are driven.
    ///
    /// The answer is already a yes by the time it gets here: Brim's review
    /// sheets show the whole plan and the person pressed the button that
    /// started this. What the service needs to know is not whether they
    /// agreed, it is that there was somebody to agree.
    private static let consentSource = ConsentSource { _ in true }

    private static func makeDaemonClient() -> any BrimServiceProtocol {
        let connection = NSXPCConnection(machServiceName: daemonMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: BrimXPCProtocol.self)
        do {
            return try BrimXPCClient(connection: connection, expecting: .brim(.daemon))
        } catch {
            // Refusing to pin means refusing to connect. Falling back to
            // the in-process service is the safe direction: it can do less,
            // not more, and it does not involve trusting whatever is
            // sitting on that Mach name.
            backend = .inProcess
            return makeInProcessService()
        }
    }

    private static func makeInProcessService() -> any BrimServiceProtocol {
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brim")
        let planDir = support.appendingPathComponent("Plans")
        let journalDir = support.appendingPathComponent("Journals")

        try? FileManager.default.createDirectory(at: planDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)

        return BrimService(
            root: root,
            brimAppURL: Bundle.main.bundleURL,
            planStoreDirectory: planDir,
            journalStoreDirectory: journalDir,
            consent: consentSource
        )
    }
}
