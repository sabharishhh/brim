import BrimCore
import Darwin
import Foundation

/// Shallow, bounded validation of the cache surfaces used by scoped package cleanup.
struct SwiftPMCacheCheck {
    let budget: ScanBudget
    let maximumEntries: Int
    private var entries = 0
    private static let stopped = ToolCleanup.CleanupError.configurationUnavailable(
        "The package cache check did not finish. Nothing was cleaned."
    )
    private static let refused = ToolCleanup.CleanupError.configurationUnavailable(
        "Could not inspect the package cache. Nothing was cleaned."
    )
    private static let changed = ToolCleanup.CleanupError.configurationUnavailable(
        "A package cache path is a link or is no longer a folder."
    )
    private static let linked = ToolCleanup.CleanupError.configurationUnavailable(
        "The package cache contains a link. Manage this cache in Xcode so its scope can be reviewed."
    )

    init(budget: ScanBudget, maximumEntries: Int) {
        self.budget = budget
        self.maximumEntries = maximumEntries
    }

    mutating func validate(_ scope: URL) throws {
        try checkBudget()
        let root = open(scope.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { throw Self.refused }
        defer { close(root) }
        // Scratch tags and database writes must not follow a cache entry outside
        // the approved scope. Read only these shallow, fixed cache surfaces.
        for parts in [[], ["manifests"], ["registry"], ["registry", "downloads"]] {
            try checkBudget()
            guard let descriptor = try openFolder(parts, root: root) else { continue }
            let folder = parts.reduce(scope) { $0.appendingPathComponent($1) }
            // The directory stream takes ownership of the duplicated/opened descriptor.
            guard let directory = fdopendir(descriptor) else {
                close(descriptor)
                throw Self.refused
            }
            defer { closedir(directory) }
            try read(directory, descriptor: descriptor)
            try checkBudget()
            var opened = stat(), current = stat()
            guard fstat(descriptor, &opened) == 0, lstat(folder.path, &current) == 0,
                  current.st_mode & S_IFMT == S_IFDIR,
                  current.st_dev == opened.st_dev, current.st_ino == opened.st_ino
            else { throw Self.refused }
        }
    }

    private func openFolder(_ parts: [String], root: Int32) throws -> Int32? {
        var descriptor = fcntl(root, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw Self.refused }
        for name in parts {
            do {
                try checkBudget()
                var before = stat()
                guard fstatat(descriptor, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT {
                        close(descriptor)
                        return nil
                    }
                    throw Self.refused
                }
                guard before.st_mode & S_IFMT == S_IFDIR else { throw Self.changed }
                let next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else { throw Self.refused }
                close(descriptor)
                descriptor = next
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, opened.st_dev == before.st_dev,
                      opened.st_ino == before.st_ino else { throw Self.refused }
            } catch {
                close(descriptor)
                throw error
            }
        }
        return descriptor
    }

    private mutating func read(_ directory: UnsafeMutablePointer<DIR>, descriptor: Int32) throws {
        while true {
            try checkBudget()
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw Self.refused }
                return
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard entries < maximumEntries else { throw Self.stopped }
            entries += 1
            var information = stat()
            guard fstatat(descriptor, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.refused }
            guard information.st_mode & S_IFMT != S_IFLNK else { throw Self.linked }
        }
    }

    private func checkBudget() throws {
        guard !budget.hasRunOut else { throw Self.stopped }
    }
}
