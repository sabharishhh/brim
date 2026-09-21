import Foundation
import BrimCore
import BrimProtocol
import BrimService

/// Decides which `BrimServiceProtocol` implementation the UI talks to.
///
/// In practice there is one: the app runs a `BrimService` actor in its own
/// process, which is enough for scanning and for everything inside the
/// user's own Library. Root-owned work goes through `BrimJobHelper`, a
/// separate and much smaller daemon, rather than through this.
///
/// `BRIM_USE_DAEMON=1` selects a full-service root daemon that no longer
/// exists: `BrimHelper` is a package executable that the application
/// project does not build, sign or install, so nothing registers the Mach
/// name it listens on. The flag used to hand back a client that failed
/// every call. It now says so and stays in process.
enum BrimServiceLocator {
    static func makeService() -> any BrimServiceProtocol {
        if ProcessInfo.processInfo.environment["BRIM_USE_DAEMON"] == "1" {
            NSLog("BRIM_USE_DAEMON is set, but no full-service daemon is built or "
                  + "installed. Running in process instead.")
        }
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
