import Foundation

/// What Brim's helper will take, asked before a plan promises it.
///
/// The helper runs as root and applies its own rules in `BrimPrivileged`.
/// `BrimCore` depends on nothing, so the planner cannot ask those rules
/// directly, and a plan used to hand the helper anything that needed an
/// administrator. The helper then refused, or was never connected, and the
/// person learned after approving that nothing had happened. This is the
/// planner's reading of the same rules; `HelperScopeAgreementTests` holds
/// the two to one answer.
public enum HelperScope {
    /// Where the helper sets aside a launchd job that no longer runs.
    public static let jobFolders: Set<String> = ["/Library/LaunchAgents", "/Library/LaunchDaemons"]

    /// Where the helper sets aside a command link that points at nothing.
    public static let commandFolders: Set<String> = ["/usr/local/bin", "/usr/local/sbin"]

    /// Where the helper sets aside a bundle an installer left owned by
    /// root, and what a bundle there is called.
    public static let bundleFolders: [String: Set<String>] = [
        "/Applications": ["app"],
        "/Library/Audio/Plug-Ins/HAL": ["driver", "plugin"],
        "/Library/Audio/Plug-Ins/Components": ["component"],
        "/Library/Audio/Plug-Ins/VST": ["vst"],
        "/Library/Audio/Plug-Ins/VST3": ["vst3"]
    ]

    /// Whether the helper would take this path, judged as it will judge it.
    ///
    /// A job file's contents are the helper's to check; a plan can only
    /// promise that the name is one it would consider. A command link can
    /// be judged completely here, because dead is a fact about the disk.
    public static func covers(_ path: String) -> Bool {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        if jobFolders.contains(folder) {
            return name.hasSuffix(".plist") && !name.hasPrefix("com.apple.")
        }
        if commandFolders.contains(folder) {
            return isDeadLink(path)
        }
        if let extensions = bundleFolders[folder] {
            return extensions.contains((name as NSString).pathExtension.lowercased())
                && !isApples(bundleAt: path)
        }
        if cacheFolders.contains(folder) {
            let lowered = name.lowercased()
            return !lowered.hasPrefix("com.apple") && !lowered.hasPrefix("com.sabharishhh.brim")
                && !isLink(path)
        }
        return payloadPackage(for: path) != nil && !isApples(bundleAt: path)
    }

    /// Caches only root can empty. A cache is rebuilt by its owner, so the
    /// helper asks only whose it is.
    public static let cacheFolders: Set<String> = ["/Library/Caches"]

    public static let receipts = URL(fileURLWithPath: "/private/var/db/receipts")

    /// The package whose receipt puts this application where the helper
    /// will take it from: directly inside the folder the package installed
    /// into, at least three levels into `/Library`. Microsoft AutoUpdate,
    /// installed by Teams' installer into Application Support, is the case.
    public static func payloadPackage(for path: String, receipts: URL = receipts) -> String? {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard (name as NSString).pathExtension.lowercased() == "app", !name.hasPrefix("."),
              let names = try? FileManager.default.contentsOfDirectory(atPath: receipts.path)
        else { return nil }
        for file in names where file.hasSuffix(".plist") && !file.lowercased().hasPrefix("com.apple.") {
            let packageID = String(file.dropLast(".plist".count))
            guard let plist = NSDictionary(contentsOf: receipts.appendingPathComponent(file)),
                  let prefix = plist["InstallPrefixPath"] as? String,
                  installFolder(prefix: prefix) == folder
            else { continue }
            return packageID
        }
        return nil
    }

    static func installFolder(prefix: String) -> String? {
        let parts = prefix.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "Library",
              !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }),
              !["Apple", "Security", "Audio", "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools"]
                .contains(parts[1])
        else { return nil }
        return "/" + parts.joined(separator: "/")
    }

    static func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) != 0 || (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// The helper also checks the signature, which a plan cannot do
    /// cheaply for every row; the identifier catches macOS's own.
    static func isApples(bundleAt path: String) -> Bool {
        let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        let identifier = (info?["CFBundleIdentifier"] as? String)?.lowercased() ?? ""
        return identifier.hasPrefix("com.apple.")
    }

    /// Folders whose contents decide how this Mac signs in or unlocks.
    /// Nothing there is removed by Brim, whoever's it is.
    static let signInFolders: Set<String> = [
        "/Library/Security/SecurityAgentPlugins"
    ]

    /// Why a plan keeps something out, or nil when the helper will take it.
    ///
    /// Anything in a root-owned folder used to become a step for the
    /// helper, which either was not connected or refused, and the person
    /// found out after approving. Kept out of the plan instead, with the
    /// reason, so the review never promises what cannot happen.
    public static func keptOut(_ path: String, bytes: Int64) -> ExcludedItem? {
        guard !covers(path) else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        // The folder allows changes, so the item itself refuses: a folder
        // that is read-only cannot be moved even out of your own Library.
        // How the Mac unlocks is not Brim's to change. An authorization
        // plug-in removed while a rule still names it is how a screen stops
        // accepting its password, so the application's own setting has to
        // turn it off.
        if signInFolders.contains(folder) {
            return ExcludedItem(
                target: path,
                reason: "Part of how this Mac signs in or unlocks. Turn it off in the app's "
                    + "own settings; Brim does not change how your Mac unlocks.",
                sizeBytes: bytes,
                canBeTickedByHand: false
            )
        }
        let reason = access(folder, W_OK) == 0
            ? "This folder is read-only, so it cannot be moved, and it stays where it is."
            : "\(folder) belongs to the system, and Brim's helper does not remove things "
            + "from it, so this stays where it is."
        return ExcludedItem(
            target: path,
            reason: reason,
            sizeBytes: bytes,
            canBeTickedByHand: false
        )
    }

    /// A symbolic link whose destination is missing. Anything this process
    /// cannot see the far end of counts as alive, as it does in the helper.
    public static func isDeadLink(_ path: String) -> Bool {
        var own = stat()
        guard lstat(path, &own) == 0, (own.st_mode & S_IFMT) == S_IFLNK else { return false }
        var far = stat()
        if stat(path, &far) == 0 {
            return false
        }
        return errno == ENOENT || errno == ENOTDIR
    }
}
