import Foundation

/// Software that insists on removing itself.
///
/// Some products cannot be uninstalled by deleting their files: they hold
/// licences on a server, they have kernel or system extensions that must be
/// withdrawn in order, or their installer scattered things no evidence
/// engine will reconstruct. Adobe, most antivirus, several VPN clients.
/// Guessing at these is how a machine ends up half broken.
///
/// So Brim looks for the vendor's own uninstaller and points at it. It
/// never runs one: the step kind is `revealVendorUninstaller`, it opens
/// Finder, and the person decides. A plan that finds one says outright
/// that it is incomplete by design, which is the honest thing to say and
/// also the useful one.
///
/// Finding one is `VendorUninstallerDetector` in `BrimCore`, because the
/// planner has to be able to ask and `BrimCore` depends on nothing. This
/// is the half that touches the machine.
public enum VendorUninstaller {

    /// Shows it to the person in Finder. Brim never runs it.
    ///
    /// `open -R` selects the file in a window rather than opening it, which
    /// is the whole distinction this step exists to preserve.
    public static func reveal(
        at path: String,
        runner: ((String, [String]) throws -> Int32)? = nil
    ) throws {
        let invoke = runner ?? run
        let status = try invoke("/usr/bin/open", ["-R", path])
        guard status == 0 else {
            throw RevealError.couldNotReveal(status)
        }
    }

    public enum RevealError: Error, LocalizedError, Equatable {
        case couldNotReveal(Int32)

        public var errorDescription: String? {
            "Brim could not show you the uninstaller in Finder."
        }
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
