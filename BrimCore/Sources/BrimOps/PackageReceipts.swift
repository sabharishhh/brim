import Foundation

/// The installer's record of what it put where: a plist and a BOM in
/// `/var/db/receipts`. Deleting the files does not remove it, so
/// `pkgutil --pkgs` keeps listing removed software. Forgetting deletes no
/// files, but the record cannot be rebuilt.
public enum PackageReceipts {
    public enum ForgetError: Error, LocalizedError, Equatable {
        case notAPackageIdentifier(String)
        case appleOwned(String)
        case noSuchReceipt(String)
        case needsRoot
        case failed(String, code: Int32)

        public var errorDescription: String? {
            switch self {
            case let .notAPackageIdentifier(id):
                "\"\(id)\" is not shaped like a package identifier, so Brim will not "
                    + "pass it to pkgutil."
            case let .appleOwned(id):
                "\(id) belongs to macOS. Forgetting an Apple receipt can confuse a "
                    + "later system update, so Brim leaves it."
            case let .noSuchReceipt(id):
                "There is no receipt for \(id) on this Mac."
            case .needsRoot:
                "Receipts live in a folder that belongs to the system, so this needs "
                    + "administrator cleanup."
            case let .failed(id, code):
                "The receipt for \(id) could not be forgotten (pkgutil exit \(code))."
            }
        }
    }

    /// Root owned, which is why forgetting needs administrator cleanup.
    public static let receiptDirectory = "/var/db/receipts"

    /// Whether a string is a package identifier and nothing else. It reaches
    /// `pkgutil` as an argument, never a shell, but a path separator or leading
    /// dash could still change its meaning.
    public static func isWellFormed(_ packageID: String) -> Bool {
        guard !packageID.isEmpty, packageID.count <= 256 else { return false }
        guard !packageID.hasPrefix("-"), !packageID.hasPrefix(".") else { return false }
        guard !packageID.contains("/"), !packageID.contains("..") else { return false }
        return packageID.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    /// Apple's own receipts are never forgotten, whoever asks.
    public static func belongsToApple(_ packageID: String) -> Bool {
        let lowered = packageID.lowercased()
        return lowered.hasPrefix("com.apple.")
    }

    /// Whether this Mac still has a receipt under that identifier.
    public static func exists(
        _ packageID: String, fileManager: FileManager = .default
    ) -> Bool {
        let base = URL(fileURLWithPath: receiptDirectory)
        return fileManager.fileExists(atPath: base.appendingPathComponent("\(packageID).plist").path)
            || fileManager.fileExists(atPath: base.appendingPathComponent("\(packageID).bom").path)
    }

    /// Everything that must be true before `pkgutil` runs, separate from the
    /// call so the administrator process applies the same rules itself.
    public static func check(
        _ packageID: String, fileManager: FileManager = .default
    ) throws {
        guard isWellFormed(packageID) else {
            throw ForgetError.notAPackageIdentifier(packageID)
        }
        guard !belongsToApple(packageID) else {
            throw ForgetError.appleOwned(packageID)
        }
        guard exists(packageID, fileManager: fileManager) else {
            throw ForgetError.noSuchReceipt(packageID)
        }
    }

    /// Forgets one receipt. Requires root, and says so.
    public static func forget(
        packageID: String,
        fileManager: FileManager = .default,
        isRoot: Bool = getuid() == 0,
        runner: ((String, [String]) throws -> Int32)? = nil
    ) async throws {
        try check(packageID, fileManager: fileManager)
        guard isRoot else { throw ForgetError.needsRoot }

        let status: Int32 = if let runner {
            try runner("/usr/sbin/pkgutil", ["--forget", packageID])
        } else {
            try await RegistrationCommand.status("/usr/sbin/pkgutil", ["--forget", packageID])
        }
        guard status == 0 else { throw ForgetError.failed(packageID, code: status) }
    }

    public static func forgetBounded(packageID: String) async throws {
        try check(packageID)
        guard getuid() == 0 else { throw ForgetError.needsRoot }
        let status = try await RegistrationCommand.status("/usr/sbin/pkgutil", ["--forget", packageID])
        guard status == 0 else { throw ForgetError.failed(packageID, code: status) }
    }
}
