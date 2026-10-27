import Foundation

/// An application bundle, as opposed to a folder whose name ends in ".app",
/// such as the cache folders named for `dev.recordly.app`.
public enum ApplicationBundle {
    /// A wrapper's executable link is an exact relationship, unlike its name
    /// or installation date. Read the link itself so a removed target still
    /// identifies the wrapper that was left behind.
    public static func executableLink(in bundle: URL, root: FileSystemRoot) -> (link: URL, target: URL)? {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let name = info["CFBundleExecutable"] as? String,
              IdentitySurface.isPathComponent(name) else { return nil }
        let link = bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return nil
        }
        let target = destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
            : link.deletingLastPathComponent().appendingPathComponent(destination)
        let boundary = root.rootURL.standardizedFileURL.path
        let realBoundary = root.rootURL.resolvingSymlinksInPath().path
        let path = target.standardizedFileURL.path
        guard [boundary, realBoundary].contains(where: { $0 == "/" || path.hasPrefix($0 + "/") }) else {
            return nil
        }
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL
        guard realBoundary == "/" || resolved.path.hasPrefix(realBoundary + "/") else { return nil }
        return (link, resolved)
    }

    /// Only proven absence disqualifies an executable wrapper as an installed
    /// claimant. Permission errors must continue protecting its data.
    public static func hasMissingLinkedExecutable(_ bundle: URL, in root: FileSystemRoot) -> Bool {
        guard let executable = executableLink(in: bundle, root: root) else { return false }
        var status = stat()
        return stat(executable.target.path, &status) != 0 && (errno == ENOENT || errno == ENOTDIR)
    }

    public static func runsInside(_ bundle: URL, owner: URL, in root: FileSystemRoot) -> Bool {
        guard let executable = executableLink(in: bundle, root: root) else { return false }
        let path = owner.resolvingSymlinksInPath().standardizedFileURL.path
        return executable.target.path.hasPrefix(path + "/")
    }

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
