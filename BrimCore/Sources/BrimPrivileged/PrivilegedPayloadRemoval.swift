import Foundation

/// The helper's rules for an application an installer put somewhere other
/// than an Applications folder.
///
/// Microsoft Teams' installer also installs Microsoft AutoUpdate, owned by
/// root, in `/Library/Application Support/Microsoft/MAU2.0`. No folder rule
/// could cover that place without covering everything else in Application
/// Support, so the proof is the installer's own record instead: the helper
/// is told a package and a name, reads the package's receipt itself, and
/// takes only an application sitting directly in the folder that receipt
/// says the package installed into. It is never handed a path.
public enum PrivilegedPayloadRemoval {
    public enum Refusal: Error, Equatable, Sendable {
        case notAPlainName(String)
        case belongsToApple(String)
        case noReceipt(String)
        case notAnInstallFolder(String)
        case notAnApplication(String)

        public var explanation: String {
            switch self {
            case .notAPlainName(let name): return "\(name) is not a plain name."
            case .belongsToApple(let name): return "\(name) is part of macOS."
            case .noReceipt(let package): return "There is no installer record for \(package)."
            case .notAnInstallFolder(let folder): return "\(folder) is not a place an installer owns."
            case .notAnApplication(let name): return "\(name) is not an application."
            }
        }
    }

    public static let receipts = URL(fileURLWithPath: "/private/var/db/receipts")

    /// Where an installed application may be taken from: the package's own
    /// folder, at least three levels into `/Library`, and not a place with
    /// a rule of its own.
    public static func installFolder(prefix: String) -> String? {
        let parts = prefix.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "Library",
              !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }),
              !["Apple", "Security", "Audio", "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools"]
                .contains(parts[1])
        else { return nil }
        return "/" + parts.joined(separator: "/")
    }

    public static func target(packageID: String, name: String, receipts: URL = receipts) throws -> URL {
        guard isPlainName(packageID) else { throw Refusal.notAPlainName(packageID) }
        guard isPlainName(name) else { throw Refusal.notAPlainName(name) }
        guard !packageID.lowercased().hasPrefix("com.apple.") else { throw Refusal.belongsToApple(packageID) }
        guard (name as NSString).pathExtension.lowercased() == "app" else { throw Refusal.notAnApplication(name) }
        let record = receipts.appendingPathComponent("\(packageID).plist")
        guard let plist = NSDictionary(contentsOf: record),
              let prefix = plist["InstallPrefixPath"] as? String
        else { throw Refusal.noReceipt(packageID) }
        guard let folder = installFolder(prefix: prefix) else { throw Refusal.notAnInstallFolder(prefix) }
        return URL(fileURLWithPath: folder).appendingPathComponent(name)
    }

    /// The package whose receipt makes `path` something the helper will
    /// take, if one does. The planner's question, answered from the same
    /// records the helper reads.
    public static func package(for path: String, receipts: URL = receipts) -> String? {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard (name as NSString).pathExtension.lowercased() == "app",
              let names = try? FileManager.default.contentsOfDirectory(atPath: receipts.path)
        else { return nil }
        for file in names where file.hasSuffix(".plist") {
            let packageID = String(file.dropLast(".plist".count))
            if let target = try? target(packageID: packageID, name: name, receipts: receipts),
               target.path == folder + "/" + name {
                return packageID
            }
        }
        return nil
    }

    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && name != ".."
    }
}

/// The helper's rule for `/Library/Caches`, which installers and root
/// daemons fill and only root can empty. A cache is by definition
/// something its owner rebuilds, so the only question is whose it is, and
/// the helper refuses anything named for Apple.
public enum PrivilegedCacheRemoval {
    public static let directory = "/Library/Caches"

    public enum Refusal: Error, Equatable, Sendable {
        case notAPlainName(String)
        case belongsToApple(String)
        case notThere
        case isALink
        case couldNotQuarantine(String)

        public var explanation: String {
            switch self {
            case .notAPlainName(let name): return "\(name) is not a plain name."
            case .belongsToApple(let name): return "\(name) belongs to macOS."
            case .notThere: return "It is not there any more."
            case .isALink: return "That is a link, not a cache."
            case .couldNotQuarantine(let why): return "It could not be set aside: \(why)"
            }
        }
    }

    public static func target(name: String) throws -> URL {
        guard PrivilegedPayloadRemoval.isPlainName(name) else { throw Refusal.notAPlainName(name) }
        guard !name.lowercased().hasPrefix("com.apple"), !name.lowercased().hasPrefix("com.sabharishhh.brim")
        else { throw Refusal.belongsToApple(name) }
        return URL(fileURLWithPath: directory).appendingPathComponent(name)
    }
}
