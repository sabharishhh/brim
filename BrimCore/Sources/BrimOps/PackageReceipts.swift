import Foundation

/// The installer's memory of what it put where.
///
/// A `.pkg` install leaves a receipt in `/var/db/receipts`: a plist and a
/// BOM listing every file. Deleting the files does not remove the receipt,
/// so `pkgutil --pkgs` keeps listing software that is long gone, and an
/// installer offered the chance to "repair" reinstates a product the
/// person thought they had removed.
///
/// Forgetting a receipt deletes no files. It is metadata, and that is what
/// makes it both safe and irreversible: nothing is destroyed except the
/// record, and the record cannot be reconstructed.
public enum PackageReceipts {

    public enum ForgetError: Error, LocalizedError, Equatable {
        case notAPackageIdentifier(String)
        case appleOwned(String)
        case noSuchReceipt(String)
        case needsRoot
        case failed(String, code: Int32)

        public var errorDescription: String? {
            switch self {
            case .notAPackageIdentifier(let id):
                return "\"\(id)\" is not shaped like a package identifier, so Brim will not "
                     + "pass it to pkgutil."
            case .appleOwned(let id):
                return "\(id) belongs to macOS. Forgetting an Apple receipt can confuse a "
                     + "later system update, so Brim leaves it."
            case .noSuchReceipt(let id):
                return "There is no receipt for \(id) on this Mac."
            case .needsRoot:
                return "Receipts live in a folder that belongs to the system, so Brim's "
                     + "helper has to do this one."
            case .failed(let id, let code):
                return "The receipt for \(id) could not be forgotten (pkgutil exit \(code))."
            }
        }
    }

    /// Where macOS keeps them. Root owned, and not writable by the person
    /// running Brim, which is why this needs the helper.
    public static let receiptDirectory = "/var/db/receipts"

    /// Whether a string is a package identifier and nothing else.
    ///
    /// This value reaches `pkgutil` as an argument. It never touches a
    /// shell, but a path separator or a leading dash would still let it
    /// mean something other than a package, so the shape is checked rather
    /// than trusted.
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

    /// Everything that has to be true before `pkgutil` is invoked.
    ///
    /// Separated from the call so the privileged daemon can apply exactly
    /// the same rules from its own side, rather than trusting that the app
    /// applied them.
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

    /// Forgets one receipt. Requires root, and says so rather than failing
    /// with something a person cannot act on.
    public static func forget(
        packageID: String,
        fileManager: FileManager = .default,
        isRoot: Bool = getuid() == 0,
        runner: ((String, [String]) throws -> Int32)? = nil
    ) throws {
        try check(packageID, fileManager: fileManager)
        guard isRoot else { throw ForgetError.needsRoot }

        let invoke = runner ?? run
        let status = try invoke("/usr/sbin/pkgutil", ["--forget", packageID])
        guard status == 0 else { throw ForgetError.failed(packageID, code: status) }
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
