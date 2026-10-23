import Foundation

/// Whether this process can read what Brim needs. macOS has no API to ask,
/// so this tries what fails without it. Listing a user-owned folder inside a
/// protected parent proves nothing, and `sudo` does not help: TCC judges the
/// responsible application, not the effective user.
public enum FullDiskAccessProbe {

    /// Opens the user's Trash for event monitoring, which Brim needs and which
    /// fails with EPERM without access. Read-only and closed at once.
    public static func isGranted(
        probing url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash")
    ) -> Bool {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
}
