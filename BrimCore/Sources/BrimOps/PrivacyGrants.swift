import Foundation

/// Clearing an application's privacy grants — accessibility, screen
/// recording, full disk access and the rest.
///
/// **These cannot be enumerated.** The TCC databases are SIP-protected and
/// unreadable even with Full Disk Access, and Apple provides no API to ask
/// what an app has been granted. So this is a write-only surface: Brim can
/// clear grants for a bundle, and cannot report which ones existed.
///
/// **Order matters more than anywhere else in an uninstall.** `tccutil`
/// resolves the bundle identifier through Launch Services, so once the
/// application bundle is gone the reset fails with
/// `kLSApplicationNotFoundErr` and the grants are stranded for good. That is
/// precisely how a machine ends up listing accessibility permissions for
/// software that was removed months ago. The reset must happen while the
/// bundle is still on disk.
public enum PrivacyGrants {

    public enum ResetError: Error, LocalizedError, Equatable {
        /// Launch Services could not resolve the bundle — almost always
        /// because the application has already been removed.
        case bundleNotFound(String)
        case failed(String, code: Int32)

        public var errorDescription: String? {
            switch self {
            case .bundleNotFound(let bundleID):
                return "Privacy grants for \(bundleID) could not be cleared because macOS can no longer "
                     + "find the application. Grants must be reset before the app is removed."
            case .failed(let bundleID, let code):
                return "Clearing privacy grants for \(bundleID) failed (tccutil exit \(code))."
            }
        }
    }

    /// `tccutil`'s exit status when Launch Services cannot resolve the bundle.
    static let bundleNotFoundExitCode: Int32 = 64

    /// Clears every privacy grant macOS holds for one bundle identifier.
    ///
    /// `All` is deliberate: an uninstall should leave no grant behind, and
    /// resetting service by service would require knowing which were granted
    /// — which is exactly what cannot be read.
    public static func resetAll(
        bundleID: String,
        runner: ((String, [String]) throws -> Int32)? = nil
    ) throws {
        let invoke = runner ?? Self.run
        let status = try invoke("/usr/bin/tccutil", ["reset", "All", bundleID])
        guard status == 0 else {
            throw status == bundleNotFoundExitCode
                ? ResetError.bundleNotFound(bundleID)
                : ResetError.failed(bundleID, code: status)
        }
    }

    /// Runs a fixed tool with fixed arguments. No caller-supplied command
    /// string ever reaches a shell; the step vocabulary forbids it.
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
