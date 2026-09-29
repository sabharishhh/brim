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
        // Applications a package put beside the Applications folders, the
        // same ones the Apps list shows. The two lists had drifted: Microsoft
        // AutoUpdate was listed as installed and still invisible here, so its
        // own folder could be offered as a leftover while it ran.
        for folder in packageInstallFolders(in: root) {
            reader.bundles += reader.entries(folder).filter { $0.pathExtension.lowercased() == "app" }
        }
        return Self(bundles: reader.bundles.sorted { $0.path < $1.path },
                    completeness: ScanCompleteness(unreadable: Array(reader.unreadable),
                                                   timedOut: Array(reader.timedOut)))
    }

    /// Folders under `/Library` that a non-Apple package installed into,
    /// read from its receipt and held to the helper's rule, so whatever is
    /// found there is also something Brim can take away.
    public static func packageInstallFolders(in root: FileSystemRoot) -> [URL] {
        let receipts = root.url(for: .systemReceipts)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: receipts.path)) ?? []
        var folders: [URL] = []
        for file in names.sorted()
        where file.hasSuffix(".plist") && !file.hasPrefix(".") && !file.lowercased().hasPrefix("com.apple.") {
            guard let plist = NSDictionary(contentsOf: receipts.appendingPathComponent(file)),
                  let prefix = plist["InstallPrefixPath"] as? String,
                  let folder = HelperScope.installFolder(prefix: prefix)
            else { continue }
            let url = root.rootURL.appendingPathComponent(String(folder.dropFirst()))
            if !folders.contains(url) { folders.append(url) }
        }
        return folders
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
