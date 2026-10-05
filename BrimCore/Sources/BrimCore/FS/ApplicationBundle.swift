import Foundation

/// An application bundle, as opposed to a folder whose name ends in ".app".
///
/// Recordly's identifier is `dev.recordly.app`, and the folders named for it
/// in `HTTPStorages` and the per-user cache end in ".app" too. Treating them
/// as applications gave each a Launch Services step, one of which failed on
/// removal, and its re-registration made a Put Back that restored every file
/// report that it could not put back.
public enum ApplicationBundle {
    /// A folder that is there and has no `Contents/Info.plist` is not an
    /// application. A path that is not there cannot be read, so its name
    /// decides, as it always did.
    public static func isBundle(atPath path: String) -> Bool {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard (trimmed as NSString).pathExtension.lowercased() == "app" else { return false }
        var info = stat()
        guard lstat(trimmed, &info) == 0 else { return true }
        return lstat(trimmed + "/Contents/Info.plist", &info) == 0
    }
}
