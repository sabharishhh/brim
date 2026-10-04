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
            case let .notAPlainName(name): "\(name) is not a plain name."
            case let .belongsToApple(name): "\(name) is part of macOS."
            case let .noReceipt(package): "There is no installer record for \(package)."
            case let .notAnInstallFolder(folder): "\(folder) is not a place an installer owns."
            case let .notAnApplication(name): "\(name) is not an application."
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
            guard let target = try? target(packageID: packageID, name: name, receipts: receipts),
                  target.path == folder + "/" + name else { continue }
            return packageID
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
            case let .notAPlainName(name): "\(name) is not a plain name."
            case let .belongsToApple(name): "\(name) belongs to macOS."
            case .notThere: "It is not there any more."
            case .isALink: "That is a link, not a cache."
            case let .couldNotQuarantine(why): "It could not be set aside: \(why)"
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

/// A preference file a removed application's installer left in
/// `/Library/Preferences`, which only root can move.
///
/// Microsoft AutoUpdate left `com.microsoft.autoupdate2.plist` there, and
/// it was the one thing a review could not take, so the app stayed listed
/// as removed with something left behind. Only a plain file named like a
/// bundle identifier is taken, never a folder: `SystemConfiguration`,
/// `Audio` and the other folders there are how this Mac is set up. Apple's
/// own files are refused, and so is `.GlobalPreferences`.
public enum PrivilegedPreferenceRemoval {
    public static let directory = "/Library/Preferences"

    public enum Refusal: Error, Equatable, Sendable {
        case notAPreferenceFile(String)
        case belongsToApple(String)
        case notThere
        case notAFile
        case couldNotQuarantine(String)

        public var explanation: String {
            switch self {
            case let .notAPreferenceFile(name): "\(name) is not an app's preference file."
            case let .belongsToApple(name): "\(name) belongs to macOS."
            case .notThere: "It is not there any more."
            case .notAFile: "That is not a file."
            case let .couldNotQuarantine(why): "It could not be set aside: \(why)"
            }
        }
    }

    public static func target(name: String) throws -> URL {
        guard PrivilegedPayloadRemoval.isPlainName(name), isPreferenceFile(name) else {
            throw Refusal.notAPreferenceFile(name)
        }
        let lowered = name.lowercased()
        guard !lowered.hasPrefix("com.apple"), !lowered.hasPrefix("com.sabharishhh.brim"),
              !isInSystemFamily(name)
        else {
            throw Refusal.belongsToApple(name)
        }
        return URL(fileURLWithPath: directory).appendingPathComponent(name)
    }

    /// The first two labels of every name macOS itself ships outside
    /// `com.apple`, such as `org.cups`, read from this Mac's own system
    /// folders. The printer list is `org.cups.printers.plist`.
    static func systemFamilies() -> Set<String> {
        var families = Set<String>()
        let candidates = ["/System/Library/LaunchDaemons", "/System/Library/LaunchAgents",
                          "/System/Library/CoreServices"]
        for folder in candidates {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                let labels = name.split(separator: ".")
                if labels.count >= 3 {
                    families.insert(labels.prefix(2).joined(separator: ".").lowercased())
                }
            }
        }
        return families
    }

    static func isInSystemFamily(_ name: String) -> Bool {
        let labels = name.lowercased().split(separator: ".")
        guard labels.count >= 3 else { return false }
        return systemFamilies().contains(labels.prefix(2).joined(separator: "."))
    }

    /// `<reverse-dns>.plist`, three labels at least before the extension.
    public static func isPreferenceFile(_ name: String) -> Bool {
        guard name.hasSuffix(".plist"), !name.hasPrefix(".") else { return false }
        let labels = name.dropLast(6).split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 3 && labels.allSatisfy { !$0.isEmpty }
    }
}
