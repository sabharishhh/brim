import Foundation

/// Clearing an application's privacy grants (accessibility, screen
/// recording, full disk access and the rest).
///
/// Brim has no supported API for enumerating another application's grants.
/// Private TCC databases are not a stable enumeration contract. A reset
/// receipt records the action, not independently verified absence.
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
        /// Launch Services could not resolve the bundle, almost always
        /// because the application has already been removed.
        case bundleNotFound(String)
        case failed(String, code: Int32)

        public var errorDescription: String? {
            switch self {
            case let .bundleNotFound(bundleID):
                "Privacy grants for \(bundleID) could not be cleared because macOS can no longer "
                    + "find the application. Grants must be reset before the app is removed."
            case let .failed(bundleID, code):
                "Clearing privacy grants for \(bundleID) failed (tccutil exit \(code))."
            }
        }
    }

    /// `tccutil`'s exit status when Launch Services cannot resolve the bundle.
    static let bundleNotFoundExitCode: Int32 = 64

    /// Requests a reset for one bundle identifier. Command completion does
    /// not independently verify each permission or managed policy.
    public static func resetAll(
        bundleID: String,
        runner: ((String, [String]) throws -> Int32)? = nil
    ) async throws {
        try validate(bundleID)
        let status: Int32 = if let runner {
            try runner("/usr/bin/tccutil", ["reset", "All", bundleID])
        } else {
            try await RegistrationCommand.status("/usr/bin/tccutil", ["reset", "All", bundleID])
        }
        guard status == 0 else {
            throw status == bundleNotFoundExitCode
                ? ResetError.bundleNotFound(bundleID)
                : ResetError.failed(bundleID, code: status)
        }
    }

    public static func resetAllBounded(bundleID: String) async throws {
        try validate(bundleID)
        let status = try await RegistrationCommand.status("/usr/bin/tccutil", ["reset", "All", bundleID])
        guard status == 0 else {
            throw status == bundleNotFoundExitCode
                ? ResetError.bundleNotFound(bundleID) : ResetError.failed(bundleID, code: status)
        }
    }

    private static func validate(_ bundleID: String) throws {
        guard getuid() != 0, !bundleID.isEmpty, !bundleID.hasPrefix("-"),
              !bundleID.contains("/"), !bundleID.contains("\0")
        else {
            throw ResetError.failed(bundleID, code: EPERM)
        }
    }
}
