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
        return false
    }

    /// Why a plan keeps something out, or nil when the helper will take it.
    ///
    /// Anything in a root-owned folder used to become a step for the
    /// helper, which either was not connected or refused, and the person
    /// found out after approving. Kept out of the plan instead, with the
    /// reason, so the review never promises what cannot happen.
    public static func keptOut(_ path: String, bytes: Int64) -> ExcludedItem? {
        guard !covers(path) else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        return ExcludedItem(
            target: path,
            reason: "\(folder) belongs to the system, and Brim's helper does not remove things "
                + "from it, so this stays where it is.",
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
        if stat(path, &far) == 0 { return false }
        return errno == ENOENT || errno == ENOTDIR
    }
}
