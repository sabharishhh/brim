import Foundation

/// Whether this process can read the parts of the disk Brim needs.
///
/// macOS offers no API to ask, so this probes by attempting the thing that
/// actually fails without it. It lives here, rather than beside the UI that
/// prompts for it, because scanning needs the same answer: an item Brim can
/// see but cannot remove has to say so, and without this probe that failure
/// surfaces as a bug rather than as a missing permission.
///
/// Two traps this avoids, both hit while diagnosing exactly that:
///
/// - Reading a user-owned directory inside a protected *parent* proves
///   nothing. `~/Library/Containers/<id>` lists fine without Full Disk
///   Access; it is the container's own metadata that is protected.
/// - `sudo` does not help. TCC is evaluated against the responsible
///   application, not the effective user, so a root shell launched from a
///   terminal without access is still a process without access.
public enum FullDiskAccessProbe {

    /// Probes by opening the user's Trash for event monitoring — an
    /// operation Brim genuinely needs, which returns EPERM without access.
    /// Read-only and immediately closed; nothing is modified.
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
