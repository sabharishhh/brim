import Foundation

/// An application bundle, as opposed to a folder whose name ends in ".app",
/// such as the cache folders named for `dev.recordly.app`.
public enum ApplicationBundle {
    /// A folder without `Contents/Info.plist` is not an application. A path that
    /// is not there cannot be read, so its name decides.
    public static func isBundle(atPath path: String) -> Bool {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard (trimmed as NSString).pathExtension.lowercased() == "app" else { return false }
        var info = stat()
        guard lstat(trimmed, &info) == 0 else { return true }
        return lstat(trimmed + "/Contents/Info.plist", &info) == 0
    }
}
