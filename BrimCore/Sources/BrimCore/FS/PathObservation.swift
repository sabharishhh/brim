import Darwin
import Foundation

/// Absence is a successful observation, not the default after a failed read.
public enum PathObservation: Codable, Equatable, Hashable, Sendable {
    case present
    case absent
    case unknown(String)

    public static func observe(_ path: String?, followingLinks: Bool = false) -> Self {
        observe(path, followingLinks: followingLinks, depth: 0)
    }

    private static func observe(_ path: String?, followingLinks: Bool, depth: Int) -> Self {
        guard depth < 16 else { return .unknown("The target's links could not be resolved.") }
        guard let path, path.hasPrefix("/") else {
            return .unknown("The target location could not be resolved.")
        }
        var information = stat()
        let result = followingLinks ? stat(path, &information) : lstat(path, &information)
        let failure = errno
        if result == 0 {
            return .present
        }
        guard failure == ENOENT || failure == ENOTDIR else {
            return .unknown("The target could not be read (\(failure)).")
        }
        // A disconnected volume has no directory entry under /Volumes.
        // Its missing mount is not evidence that its contents were deleted.
        let components = URL(fileURLWithPath: path).pathComponents
        if followingLinks, let linked = linkedObservation(components, depth: depth) {
            return linked
        }
        if components.count > 2, components[1] == "Volumes" {
            var mount = stat()
            let mountPath = "/Volumes/" + components[2]
            if lstat(mountPath, &mount) != 0 {
                return .unknown("The volume containing the target is unavailable.")
            }
        }
        return .absent
    }

    private static func linkedObservation(_ components: [String], depth: Int) -> Self? {
        var prefix = URL(fileURLWithPath: "/")
        for index in components.indices.dropFirst() {
            prefix.appendPathComponent(components[index])
            var link = stat()
            if lstat(prefix.path, &link) == 0, (link.st_mode & S_IFMT) == S_IFLNK {
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: prefix.path)
                else { return .unknown("A target link could not be read.") }
                var resolved = destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                    : prefix.deletingLastPathComponent().appendingPathComponent(destination)
                for suffix in components.dropFirst(index + 1) {
                    resolved.appendPathComponent(suffix)
                }
                return observe(resolved.standardizedFileURL.path, followingLinks: true, depth: depth + 1)
            }
        }
        return nil
    }

    public var isPresent: Bool {
        self == .present
    }

    public var isAbsent: Bool {
        self == .absent
    }

    public var isUnknown: Bool {
        if case .unknown = self {
            return true
        }
        return false
    }
}
