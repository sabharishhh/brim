import Foundation

/// Installed bundles in application directories, including vendor subfolders.
/// Stops at bundles; their embedded code is read by BundleSurfaceReader.
public struct InstalledBundleInventory: Sendable {
    public let bundles: [URL]
    public let completeness: ScanCompleteness

    public static func read(in root: FileSystemRoot) -> Self {
        var reader = Reader(root: root)
        var directories = [root.url(for: .applications), root.url(for: .userApplications),
                           root.rootURL.appendingPathComponent("System/Applications")]
        for user in reader.entries(root.url(for: .users)) {
            directories.append(user.appendingPathComponent("Applications"))
        }
        for volume in reader.entries(root.url(for: .volumes)) {
            directories.append(volume.appendingPathComponent("Applications"))
            directories.append(volume.appendingPathComponent("Users/\(root.userName)/Applications"))
        }
        for directory in directories {
            reader.walk(directory, depth: 0)
        }
        return Self(bundles: reader.bundles.sorted { $0.path < $1.path },
                    completeness: ScanCompleteness(unreadable: Array(reader.unreadable),
                                                   timedOut: Array(reader.timedOut)))
    }

    private struct Reader {
        let root: FileSystemRoot
        let budget = ScanBudget(total: 5)
        var bundles: [URL] = []
        var visited = Set<String>()
        var unreadable = Set<String>()
        var timedOut = Set<String>()

        mutating func entries(_ directory: URL) -> [URL] {
            guard !budget.hasRunOut else { timedOut.insert(directory.path); return [] }
            do {
                return try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                    options: [.skipsHiddenFiles]
                ).sorted { $0.path < $1.path }
            } catch {
                let failure = error as NSError
                let cocoaMissing = failure.domain == NSCocoaErrorDomain
                    && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)
                let posixMissing = failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT)
                if !cocoaMissing, !posixMissing {
                    unreadable.insert(directory.path)
                }
                return []
            }
        }

        mutating func walk(_ directory: URL, depth: Int) {
            var info = stat()
            if lstat(directory.path, &info) != 0, errno == ENOENT {
                return
            }
            let path = directory.resolvingSymlinksInPath().path
            let boundary = root.rootURL.resolvingSymlinksInPath().path
            guard boundary == "/" || path == boundary || path.hasPrefix(boundary + "/") else {
                unreadable.insert(directory.path)
                return
            }
            guard visited.insert(path).inserted else { return }
            guard depth < 8, visited.count <= 4096 else { timedOut.insert(directory.path); return }
            for item in entries(directory) {
                do {
                    let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    guard values.isDirectory == true else { continue }
                    if item.pathExtension.lowercased() == "app" {
                        bundles.append(item)
                    } else if values.isPackage != true {
                        walk(item, depth: depth + 1)
                    }
                } catch { unreadable.insert(item.path) }
            }
        }
    }
}
