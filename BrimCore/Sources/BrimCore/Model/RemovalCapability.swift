import Foundation

/// Whether Brim can actually take a path away, as it is running.
///
/// The rule is Unix's, and it is easy to get backwards: **removing a file
/// needs write permission on the directory holding it, not on the file.**
/// The name lives in the directory, and unlinking it edits the directory.
/// So a world-writable file in a root-owned folder cannot be removed, and a
/// read-only file in your own folder can.
///
/// Brim asked the file, which happened to give the right answer for
/// `/Library/LaunchAgents/com.google.keystone.agent.plist` because both it
/// and its directory refuse, and would have given the wrong one the moment
/// the two disagreed. The cost of that was a screen offering to remove two
/// jobs, an authorization, and then "2 targets still remain" with no reason
/// given.
public enum RemovalCapability {

    /// What it would take to remove this path.
    public static func forDeleting(_ path: String) -> Capability {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return .refusedByOS }

        if access(parent, W_OK) == 0 {
            // The directory allows it. A restricted flag on the item
            // itself still wins, and no permission overrides that one.
            //
            // `lstat`, because the flags that matter are the ones on the
            // thing being unlinked. `stat` follows a symbolic link and
            // answers about the target, which for a broken link fails
            // outright and skipped this check entirely.
            var info = stat()
            if lstat(path, &info) == 0, (info.st_flags & UInt32(SF_RESTRICTED)) != 0 {
                return .refusedByOS
            }
            return .ok
        }

        switch errno {
        // Not ours to write to. A root-owned directory needs something
        // running as root, which is what the helper is for.
        case EACCES: return .needsHelper
        // The directory is there but the process is not allowed to look,
        // which on macOS is usually the privacy layer rather than the
        // permission bits.
        case EPERM: return .needsFullDiskAccess
        default: return .needsHelper
        }
    }

    /// Why a whole folder refuses, for a refusal that covers several
    /// things at once.
    ///
    /// `explanation` is written about one item, which is right on a row and
    /// wrong in a summary: fourteen commands in one directory produced
    /// fourteen copies of "This sits in a folder that belongs to the
    /// system, so removing it needs an administrator", and pluralising the
    /// sentence around it left "This sits ... removing it ... They are all
    /// in /usr/local/bin". Anchoring the sentence on the folder instead
    /// makes one wording correct for one item and for fourteen.
    ///
    /// Nil where the folder is not the reason. A restricted flag belongs to
    /// the item, and saying the directory is at fault would send somebody
    /// after the wrong thing.
    public static func folderExplanation(_ capability: Capability, folder: String) -> String? {
        switch capability {
        case .ok:
            return nil
        case .needsHelper:
            return "\(folder) belongs to the system, so removing anything in it needs an "
                 + "administrator."
        case .needsFullDiskAccess:
            return "\(folder) is one macOS keeps private. Brim needs Full Disk Access to "
                 + "change what is in it."
        case .refusedByOS:
            return nil
        }
    }

    /// Why a person is not being offered a button, in their terms.
    public static func explanation(_ capability: Capability) -> String? {
        switch capability {
        case .ok:
            return nil
        case .needsHelper:
            return "This sits in a folder that belongs to the system, so removing it needs an "
                 + "administrator."
        case .needsFullDiskAccess:
            return "Needs Full Disk Access."
        case .refusedByOS:
            return "macOS protects this one and will not let anything remove it."
        }
    }
}
