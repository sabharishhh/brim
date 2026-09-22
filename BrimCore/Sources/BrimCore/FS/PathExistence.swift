import Foundation

/// Whether something is at a path, asked about the path itself.
///
/// `FileManager.fileExists(atPath:)` follows symbolic links, so it answers a
/// question about the *target*. For a link whose target has gone it returns
/// false, and the link is standing right there.
///
/// That is not a detail. A broken symlink is one of the commonest things
/// software leaves behind: `/usr/local/bin/zed` pointing into a `Zed.app`
/// that was dragged to the Trash months ago, and six more like it from
/// Docker and a removed Python framework. Fourteen of them were on this Mac.
///
/// What happened to them is the reason this type exists. The sweep found
/// them, because `LeftoversScanner` judges a link by `isSymbolicLinkKey`.
/// They were listed, grouped and ticked. Then `FootprintProjector` asked
/// `fileExists` before building the footprint, got false for every one, and
/// planned nothing. The removal sheet opened with an empty list, "Frees now:
/// Empty", and an Authorize button that would have reported success having
/// done nothing at all. `Executor` would have skipped them a second time and
/// written `already_gone` into the journal.
///
/// Meanwhile `verify` was already doing it correctly, with a comment saying
/// "Re-observe targets using lstat to avoid traversing symlinks". So one
/// component knew, three did not, and the product could find a thing and
/// then be unable to remove it. This is the one answer all of them use.
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

    /// True when the entry is a symbolic link whose target is not there.
    ///
    /// Separated out because the two facts drive different sentences: a
    /// broken link is removable and worth removing, while a link that
    /// resolves is doing its job.
    public static func isDanglingSymlink(atPath path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        guard info.st_mode & S_IFMT == S_IFLNK else { return false }
        var target = stat()
        return stat(path, &target) != 0
    }
}
