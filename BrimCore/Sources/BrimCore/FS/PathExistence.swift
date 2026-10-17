import Foundation

/// Whether something is at a path, asked about the path itself.
/// `FileManager.fileExists(atPath:)` follows links and returns false for a
/// broken one, which is one of the commonest things software leaves behind.
/// Every component that finds, plans, removes or verifies uses this, so
/// nothing is found and then silently skipped.
public enum PathExistence {

    /// True when there is a directory entry at this path, whatever it points
    /// at and whether or not that target exists.
    public static func exists(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    public static func exists(at url: URL) -> Bool {
        exists(atPath: url.path)
    }

    /// True when the entry is a symbolic link whose target is not there. A
    /// broken link is worth removing; one that resolves is doing its job.
    public static func isDanglingSymlink(atPath path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        guard info.st_mode & S_IFMT == S_IFLNK else { return false }
        var target = stat()
        return stat(path, &target) != 0
    }
}
