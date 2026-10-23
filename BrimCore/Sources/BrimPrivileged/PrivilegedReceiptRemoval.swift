import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// The rules applied before forgetting an installer receipt in
/// `/var/db/receipts`. Nothing is deleted but the record, which cannot be
/// rebuilt:
/// 1. The interface cannot express a path: only a package identifier, with
///    no separators or dot-dot, never handed to a shell.
/// 2. The receipt must already exist, so this cannot probe the disk.
/// 3. Nothing of Apple's, ever: a missing system receipt can confuse a later
///    macOS update.
public enum PrivilegedReceiptRemoval {
    /// Where macOS keeps them, and the only folder this looks in.
    public static let receiptDirectory = "/var/db/receipts"

    public enum Refusal: Error, Equatable, Sendable {
        case notAPackageIdentifier(String)
        case belongsToApple(String)
        case noSuchReceipt(String)
        case pkgutilFailed(Int32)
        case payloadNotGone

        public var explanation: String {
            switch self {
            case let .notAPackageIdentifier(id):
                "\"\(id)\" is not shaped like a package identifier, so administrator "
                    + "cleanup will not pass it on."
            case let .belongsToApple(id):
                "\(id) belongs to macOS. Forgetting an Apple receipt can confuse a "
                    + "later system update, and it cannot be put back."
            case let .noSuchReceipt(id):
                "There is no receipt for \(id) on this Mac."
            case .payloadNotGone:
                "The package payload remains or could not be checked. Its installer record was kept."
            case let .pkgutilFailed(code):
                "pkgutil would not forget it (exit \(code))."
            }
        }
    }

    /// The complete file listing is qualified here independently, rather than
    /// trusting the app's earlier read or accepting a path.
    static func checkPayload(listing: String, prefix: String,
                             exists: (String) throws -> Bool) throws {
        let files = listing.split(separator: "\n").map(String.init)
        guard !files.isEmpty, files.count <= 100_000,
              !prefix.split(separator: "/").contains("..") else { throw Refusal.payloadNotGone }
        let base = URL(fileURLWithPath: "/").appendingPathComponent(prefix).standardizedFileURL
        for file in files {
            guard !file.hasPrefix("/"), !file.contains("\0"),
                  !file.split(separator: "/").contains("..") else { throw Refusal.payloadNotGone }
            let path = base.appendingPathComponent(file).standardizedFileURL.path
            guard path.hasPrefix(base.path == "/" ? "/" : base.path + "/"),
                  try !exists(path) else { throw Refusal.payloadNotGone }
        }
    }

    /// Whether a string is a package identifier and nothing else. Passed to
    /// `pkgutil` as an argument, never a shell, but a separator or leading dash
    /// could still change its meaning.
    public static func isWellFormed(_ packageID: String) -> Bool {
        guard !packageID.isEmpty, packageID.count <= 256 else { return false }
        guard !packageID.hasPrefix("-"), !packageID.hasPrefix(".") else { return false }
        guard !packageID.contains("/"), !packageID.contains("..") else { return false }
        return packageID.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    public static func belongsToApple(_ packageID: String) -> Bool {
        packageID.lowercased().hasPrefix("com.apple.")
    }

    /// Everything that has to hold before `pkgutil` is invoked.
    public static func check(
        _ packageID: String,
        receiptExists: (String) -> Bool = { name in
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: receiptDirectory)
                    .appendingPathComponent(name).path
            )
        }
    ) throws {
        guard isWellFormed(packageID) else {
            throw Refusal.notAPackageIdentifier(packageID)
        }
        guard !belongsToApple(packageID) else {
            throw Refusal.belongsToApple(packageID)
        }
        guard receiptExists("\(packageID).plist") || receiptExists("\(packageID).bom") else {
            throw Refusal.noSuchReceipt(packageID)
        }
    }
}
