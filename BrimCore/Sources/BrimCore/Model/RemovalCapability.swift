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
            var info = stat()
            if stat(path, &info) == 0, (info.st_flags & UInt32(SF_RESTRICTED)) != 0 {
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
