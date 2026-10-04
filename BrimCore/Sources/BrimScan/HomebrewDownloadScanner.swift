import BrimCore
import Darwin
import Foundation

/// Reads completed download files without claiming the Homebrew cache folder.
public enum HomebrewDownloadScanner {
    public struct Result: Sendable {
        public let files: [URL]
        public let measurement: ArtifactSize
        public let completeness: ScanCompleteness
    }

    public static func root(home: URL) -> URL {
        home.appendingPathComponent("Library/Caches/Homebrew/downloads").standardizedFileURL
    }

    /// An incomplete read supplies no cleanup targets. Unknown entries stay in place.
    public static func scan(
        home: URL, budget: ScanBudget = ScanBudget(total: 5), maximumEntries: Int = 20000
    ) -> Result {
        let folder = root(home: home)
        guard !budget.hasRunOut else { return refused(folder, timedOut: true) }
        let descriptor: Int32
        do {
            guard let opened = try openRoot(home: home) else { return empty() }
            descriptor = opened
        } catch { return refused(folder) }
        // fdopendir takes ownership of this descriptor.
        guard let directory = fdopendir(descriptor) else {
            close(descriptor)
            return refused(folder)
        }
        defer { closedir(directory) }
        let listing: DownloadListing
        do {
            listing = try readDirectory(
                directory,
                descriptor: descriptor,
                folder: folder,
                budget: budget,
                maximumEntries: maximumEntries
            )
        } catch ReadError.timedOut {
            return refused(folder, timedOut: true)
        } catch {
            return refused(folder)
        }
        guard !budget.hasRunOut else { return refused(folder, timedOut: true) }
        guard sameRoot(descriptor, folder: folder) else { return refused(folder) }
        return completedResult(listing)
    }

    private static func readDirectory(
        _ directory: UnsafeMutablePointer<DIR>, descriptor: Int32, folder: URL,
        budget: ScanBudget, maximumEntries: Int
    ) throws -> DownloadListing {
        var entries = 0
        var listing = DownloadListing()
        while true {
            guard !budget.hasRunOut else { throw ReadError.timedOut }
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw ReadError.refused }
                return listing
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            entries += 1
            guard entries <= maximumEntries else { throw ReadError.timedOut }
            try listing.append(name, descriptor: descriptor, folder: folder)
        }
    }

    private struct DownloadListing {
        var files: [(URL, stat)] = []
        var unfinished = Set<String>()

        mutating func append(_ name: String, descriptor: Int32, folder: URL) throws {
            if name.hasSuffix(".incomplete") {
                unfinished.insert(String(name.dropLast(".incomplete".count)))
                return
            }
            guard recognized(name) else { return }
            var information = stat()
            guard fstatat(descriptor, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ReadError.refused
            }
            guard information.st_mode & S_IFMT == S_IFREG else { return }
            files.append((folder.appendingPathComponent(name), information))
        }
    }

    private static func completedResult(_ listing: DownloadListing) -> Result {
        var counted = Set<FileKey>()
        var logical: Int64 = 0, allocated: Int64 = 0
        let completed = listing.files.filter { !listing.unfinished.contains($0.0.lastPathComponent) }
        for (_, information) in completed {
            guard counted.insert(FileKey(device: information.st_dev, inode: information.st_ino)).inserted
            else { continue }
            logical += max(0, information.st_size)
            allocated += max(0, Int64(information.st_blocks) * 512)
        }
        return Result(
            files: completed.map(\.0).sorted { $0.path < $1.path },
            measurement: ArtifactSize(logicalBytes: logical, allocatedBytes: allocated, state: .complete),
            completeness: .complete
        )
    }

    /// Rechecks one approved leaf at planning and mutation boundaries.
    public static func classification(at url: URL, home: URL) -> ArtifactClassification? {
        let candidate = url.standardizedFileURL
        let folder = root(home: home)
        guard candidate.deletingLastPathComponent() == folder,
              recognized(candidate.lastPathComponent) else { return nil }
        guard let descriptor = try? openRoot(home: home) else { return nil }
        defer { close(descriptor) }
        var information = stat()
        guard fstatat(descriptor, candidate.lastPathComponent, &information, AT_SYMLINK_NOFOLLOW) == 0,
              information.st_mode & S_IFMT == S_IFREG else { return nil }
        var partial = stat()
        guard fstatat(descriptor, candidate.lastPathComponent + ".incomplete", &partial, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT, sameRoot(descriptor, folder: folder) else { return nil }
        return .dependencyStore
    }

    private struct FileKey: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private enum ReadError: Error { case refused, timedOut }

    private static func openRoot(home: URL) throws -> Int32? {
        var descriptor = open(home.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ReadError.refused }
        for name in ["Library", "Caches", "Homebrew", "downloads"] {
            let next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            let failure = errno
            close(descriptor)
            guard next >= 0 else {
                if failure == ENOENT {
                    return nil
                }
                throw ReadError.refused
            }
            descriptor = next
        }
        return descriptor
    }

    private static func sameRoot(_ descriptor: Int32, folder: URL) -> Bool {
        var opened = stat(), current = stat()
        return fstat(descriptor, &opened) == 0 && lstat(folder.path, &current) == 0
            && current.st_mode & S_IFMT == S_IFDIR
            && opened.st_dev == current.st_dev && opened.st_ino == current.st_ino
    }

    private static func recognized(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count > 66, bytes[64] == 45, bytes[65] == 45,
              !name.hasSuffix(".incomplete") else { return false }
        return bytes.prefix(64).allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    private static func empty() -> Result {
        Result(files: [], measurement: ArtifactSize(state: .complete), completeness: .complete)
    }

    private static func refused(_ folder: URL, timedOut: Bool = false) -> Result {
        let completeness = ScanCompleteness(
            unreadable: timedOut ? [] : [folder.path], timedOut: timedOut ? [folder.path] : []
        )
        return Result(
            files: [],
            measurement: ArtifactSize(state: .unknown, completeness: completeness),
            completeness: completeness
        )
    }
}
