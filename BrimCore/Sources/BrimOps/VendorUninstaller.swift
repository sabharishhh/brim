import Foundation

/// Software that insists on removing itself (licences on a server, system
/// extensions withdrawn in order). Brim finds the vendor's uninstaller and
/// reveals it in Finder; it never runs one, and the plan says it is
/// incomplete by design. Detection is `VendorUninstallerDetector` in
/// `BrimCore`; this is the half that touches the machine.
public enum VendorUninstaller {

    /// Shows it in Finder; never runs it. `open -R` selects the file rather than
    /// opening it.
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
        // Nothing reads either stream, and a pipe nobody reads stalls a tool.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
