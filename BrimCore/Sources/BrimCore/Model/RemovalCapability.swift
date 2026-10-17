import Foundation

/// Whether Brim can take a path away, as it is running. Removing a file
/// needs write permission on the folder holding it, not on the file: the
/// name lives in the folder. So a world-writable file in a root-owned folder
/// cannot be removed, and a read-only file in your own folder can.
public enum RemovalCapability {
    /// Flags only macOS can set, under System Integrity Protection, such as
    /// `SF_NOUNLINK` on WebKit's per-app temporary folders. Nobody can remove
    /// such an item, root included.
    static let systemProtectionFlags = UInt32(SF_RESTRICTED) | UInt32(SF_NOUNLINK)

    /// Something macOS protects for itself. It is never an app's to remove,
    /// so it is not part of any app's footprint.
    public static func isProtectedBySystem(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_flags & systemProtectionFlags) != 0
    }

    /// What it would take to remove this path.
    public static func forDeleting(_ path: String) -> Capability {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return .refusedByOS }

        if access(parent, W_OK) == 0 {
            // The folder allows it, but a restricted flag on the item still wins.
            // `lstat`, because the flags on the thing being unlinked matter; `stat`
            // follows a link and fails outright for a broken one.
            var info = stat()
            let described = lstat(path, &info) == 0
            if described, (info.st_flags & systemProtectionFlags) != 0 {
                return .refusedByOS
            }
            // Moving a folder rewrites its own `..` entry, so the folder itself must be
            // writable too; a file or link does not need that. Asked of the folder
            // itself, never through a link.
            if described, (info.st_mode & S_IFMT) == S_IFDIR, access(path, W_OK) != 0 {
                return errno == EPERM ? .needsFullDiskAccess : .needsHelper
            }
            return .ok
        }

        switch errno {
        // A root-owned folder needs administrator cleanup.
        case EACCES: return .needsHelper
        // The folder is there but this process may not look: on macOS usually the
        // privacy layer, not the permission bits.
        case EPERM: return .needsFullDiskAccess
        default: return .needsHelper
        }
    }

    /// Why a whole folder refuses, worded about the folder so one sentence is
    /// right for one item or fourteen. Nil where the folder is not the reason:
    /// a restricted flag belongs to the item.
    public static func folderExplanation(_ capability: Capability, folder: String) -> String? {
        switch capability {
        case .ok:
            return nil
        case .needsHelper:
            // In a person's own Library the folder is theirs; an installer that ran as
            // an administrator left the item owned by root.
            if folder.hasPrefix("/Users/") || folder.hasPrefix("~/") {
                return "An installer left this owned by an administrator. Finder can move it to the Trash "
                    + "and asks for your password."
            }
            return "\(folder) belongs to the system. Removing anything in it needs an "
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
            nil
        case .needsHelper:
            "This is in a folder that belongs to the system. Removing it needs an "
                + "administrator."
        case .needsFullDiskAccess:
            "Needs Full Disk Access."
        case .refusedByOS:
            "macOS protects this one and will not let anything remove it."
        }
    }
}
