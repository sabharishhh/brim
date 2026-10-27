import Darwin
import Foundation

/// A directory-only application search. Asking Foundation whether each asset
/// is a package made vendor resource trees dominate the ownership search.
/// Native entry types skip ordinary files without allocating URLs or reading
/// their metadata. Bundles are leaves; their own readers inspect embedded code.
public enum ApplicationDirectoryScan {
    public struct Result: Sendable {
        public let bundles: [URL]
        public let completeness: ScanCompleteness
    }

    public static func read(
        in directories: [URL], boundary: URL, budget: ScanBudget,
        maximumDepth: Int = 32, maximumDirectories: Int = 100_000
    ) -> Result {
        var walk = Walk(boundary: canonicalPath(boundary), budget: budget,
                        maximumDepth: maximumDepth, maximumDirectories: maximumDirectories)
        var queue = directories.map { ($0, 0) }
        var index = 0
        while index < queue.count {
            let (directory, depth) = queue[index]
            index += 1
            guard !budget.hasRunOut else { walk.timedOut.insert(directory.path); break }
            queue += walk.children(in: directory, depth: depth).map { ($0, depth + 1) }
        }
        return Result(bundles: walk.bundles.sorted { $0.path < $1.path },
                      completeness: ScanCompleteness(unreadable: Array(walk.unreadable),
                                                     timedOut: Array(walk.timedOut)))
    }

    private static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private struct Walk {
        let boundary: String
        let budget: ScanBudget
        let maximumDepth: Int
        let maximumDirectories: Int
        var visited = Set<String>()
        var bundles: [URL] = []
        var unreadable = Set<String>()
        var timedOut = Set<String>()

        private static let packageExtensions: Set<String> = [
            "framework", "bundle", "plugin", "appex", "xpc", "systemextension", "pkg", "dmg",
            "photoslibrary", "xcodeproj", "xcworkspace", "component", "vst", "vst3", "aaxplugin"
        ]

        mutating func children(in directory: URL, depth: Int) -> [URL] {
            var presence = stat()
            if lstat(directory.path, &presence) != 0, errno == ENOENT || errno == ENOTDIR {
                return []
            }
            let path = ApplicationDirectoryScan.canonicalPath(directory)
            guard boundary == "/" || path == boundary || path.hasPrefix(boundary + "/") else {
                unreadable.insert(directory.path); return []
            }
            guard visited.insert(path).inserted else { return [] }
            guard depth <= maximumDepth, visited.count <= maximumDirectories else {
                timedOut.insert(directory.path); return []
            }
            guard let stream = open(directory) else { return [] }
            defer { closedir(stream) }
            var children: [URL] = []
            while let entry = readdir(stream) {
                guard !budget.hasRunOut else { timedOut.insert(directory.path); break }
                let type = entry.pointee.d_type
                guard type == DT_DIR || type == DT_LNK || type == DT_UNKNOWN, let child = child(
                    entry.pointee,
                    in: directory
                ) else { continue }
                if shouldDescend(into: child) {
                    children.append(child)
                }
            }
            return children.sorted { $0.path < $1.path }
        }

        private mutating func open(_ directory: URL) -> UnsafeMutablePointer<DIR>? {
            let stream = opendir(directory.path)
            if stream == nil, errno != ENOENT {
                unreadable.insert(directory.path)
            }
            return stream
        }

        private mutating func shouldDescend(into child: URL) -> Bool {
            let ext = child.pathExtension.lowercased()
            if ext == "app" {
                bundles.append(child); return false
            }
            return !Self.packageExtensions.contains(ext)
        }

        private mutating func child(_ entry: dirent, in directory: URL) -> URL? {
            var nameBytes = entry.d_name
            let name = withUnsafePointer(to: &nameBytes) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            guard !name.hasPrefix(".") else { return nil }
            let child = directory.appendingPathComponent(name, isDirectory: true)
            guard entry.d_type != DT_DIR else { return child }
            let real = ApplicationDirectoryScan.canonicalPath(child)
            guard boundary == "/" || real == boundary || real.hasPrefix(boundary + "/") else {
                unreadable.insert(child.path); return nil
            }
            var information = stat()
            guard stat(child.path, &information) == 0 else {
                if errno != ENOENT, errno != ENOTDIR {
                    unreadable.insert(child.path)
                }
                return nil
            }
            return information.st_mode & S_IFMT == S_IFDIR ? child : nil
        }
    }
}
