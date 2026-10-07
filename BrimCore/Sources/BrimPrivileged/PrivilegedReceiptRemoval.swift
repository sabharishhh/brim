import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// The rules the daemon applies before forgetting an installer receipt.
///
/// Forgetting a receipt deletes no files. It removes the installer's
/// record from `/var/db/receipts`, which is why the product keeps showing
/// in `pkgutil --pkgs` long after it is gone and why an installer can
/// offer to "repair" something the person thought they had removed. The
/// folder belongs to root, so this is the daemon's job.
///
/// The same three ideas as `PrivilegedJobRemoval`, and they matter as much
/// here even though nothing is deleted:
///
/// 1. **The interface cannot express a path.** A caller names a package
///    identifier. The daemon builds everything else, and refuses anything
///    with a separator or a dot-dot in it, so there is nothing to traverse
///    and nothing to hand a shell.
/// 2. **The receipt has to already exist.** A caller cannot use this to
///    probe the filesystem or to make `pkgutil` do something else.
/// 3. **Nothing of Apple's, ever.** Forgetting a system receipt can leave
///    a later macOS update unable to reason about what is installed, and
///    the record cannot be rebuilt. Refused by the daemon by name, rather
///    than trusting the caller to have filtered them out.
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

    /// The helper independently qualifies the complete file listing, rather
    /// than trusting the app's earlier read or accepting an arbitrary path.
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

    /// Whether a string is a package identifier and nothing else.
    ///
    /// It reaches `pkgutil` as an argument and never touches a shell, but
    /// a separator or a leading dash would still let it mean something
    /// other than a package. Checked rather than trusted.
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
