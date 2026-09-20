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

    private static func makeDaemonClient() -> any BrimServiceProtocol {
        let connection = NSXPCConnection(machServiceName: daemonMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: BrimXPCProtocol.self)
        connection.resume()
        return BrimXPCClient(connection: connection, requireCodeSigning: false)
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
            journalStoreDirectory: journalDir
        )
    }
}
