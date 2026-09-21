import Foundation

/// Whether a path is a launchd job file.
///
/// Decided by where it lives, which is the only thing launchd itself goes
/// on: it loads what is in these directories and ignores everything else.
/// This matters when a path is named for removal directly, with no
/// application to discover it from, because a job has to be unloaded before
/// its file is taken away. Remove the file first and the job keeps running
/// until the next login, with nothing left on disk to explain it.
public enum LaunchdJobFile {

    static let directories = ["LaunchAgents", "LaunchDaemons"]

    public static func isOne(_ url: URL) -> Bool {
        guard url.pathExtension == "plist" else { return false }
        return directories.contains(url.deletingLastPathComponent().lastPathComponent)
    }
}
