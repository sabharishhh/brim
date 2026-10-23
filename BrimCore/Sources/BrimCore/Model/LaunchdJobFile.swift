import Foundation

/// Whether a path is a launchd job file, decided by where it lives, as
/// launchd decides. A job must be unloaded before its file goes, or it keeps
/// running until the next login with nothing on disk to explain it.
public enum LaunchdJobFile {

    static let directories = ["LaunchAgents", "LaunchDaemons"]

    public static func isOne(_ url: URL) -> Bool {
        guard url.pathExtension == "plist" else { return false }
        return directories.contains(url.deletingLastPathComponent().lastPathComponent)
    }
}
