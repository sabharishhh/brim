import Darwin
import Foundation

/// Reads one entry at a time and keeps only the open directory chain.
/// Descendants are inspected relative to their pinned parent descriptor.
struct ArtifactSizeTraversal {
    private typealias DirectoryParent = (descriptor: Int32, name: String)
    let budget: ScanBudget
    let maximumEntries: Int
    private var entries = 0
    private var counted = Set<FileID>()
    private var logical: Int64 = 0
    private var allocated: Int64 = 0
    private var unreadable: [String] = []
    private var timedOut: [String] = []
    private var readAnything = false

    init(budget: ScanBudget, maximumEntries: Int) {
        self.budget = budget
        self.maximumEntries = max(0, maximumEntries)
    }

    mutating func measure(roots: [URL]) -> ArtifactSize {
        var remaining = roots
        while let root = remaining.popLast() {
            guard !budget.hasRunOut else {
                timedOut += [root.path] + remaining.map(\.path)
                break
            }
            if !read(root: root) {
                timedOut += remaining.map(\.path)
                break
            }
        }
        let completeness = ScanCompleteness(unreadable: unreadable, timedOut: timedOut)
        let state: ArtifactSize.State = if completeness.isComplete {
            .complete
        } else if readAnything {
            .partial
        } else {
            .unknown
        }
        return ArtifactSize(
            logicalBytes: logical, allocatedBytes: allocated,
            state: state, completeness: completeness
        )
    }

    private mutating func read(root: URL) -> Bool {
        var information = stat()
        guard lstat(root.path, &information) == 0 else {
            // Only these two errors establish absence. Permissions and link
            // loops leave the size unknown and must remain visible.
            if errno != ENOENT, errno != ENOTDIR {
                unreadable.append(root.path)
            }
            return true
        }
        readAnything = true
        guard information.st_mode & S_IFMT == S_IFDIR else {
            count(information)
            return true
        }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard let frame = directory(
            descriptor: descriptor, path: root.path, information: information, parent: nil
        ) else { return true }
        return readDirectories(startingAt: frame)
    }

    private mutating func readDirectories(startingAt root: DirectoryFrame) -> Bool {
        var stack = [root]
        defer { for frame in stack {
            closedir(frame.directory)
        } }
        while let frame = stack.last {
            guard !budget.hasRunOut else {
                timedOut += stack.map(\.path)
                return false
            }
            errno = 0
            guard let entry = readdir(frame.directory) else {
                if errno != 0 {
                    unreadable.append(frame.path)
                }
                if !frame.isStillNamed {
                    unreadable.append(frame.path)
                }
                closedir(frame.directory)
                stack.removeLast()
                continue
            }
            let name = entryName(entry)
            guard name != ".", name != ".." else { continue }
            guard entries < maximumEntries else {
                timedOut += stack.map(\.path)
                return false
            }
            entries += 1
            if let child = readChild(name, of: frame, depth: stack.count) {
                stack.append(child)
            }
        }
        return true
    }

    private mutating func readChild(_ name: String, of parent: DirectoryFrame, depth: Int) -> DirectoryFrame? {
        let path = URL(fileURLWithPath: parent.path).appendingPathComponent(name).path
        var information = stat()
        guard fstatat(parent.descriptor, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            unreadable.append(path)
            return nil
        }
        readAnything = true
        guard information.st_mode & S_IFMT == S_IFDIR else {
            count(information)
            return nil
        }
        // A deeply nested tree must not exhaust the process's descriptor limit.
        guard depth < 128 else {
            unreadable.append(path)
            return nil
        }
        let descriptor = openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        return directory(
            descriptor: descriptor, path: path, information: information,
            parent: (descriptor: parent.descriptor, name: name)
        )
    }

    private mutating func directory(
        descriptor: Int32, path: String, information: stat, parent: DirectoryParent?
    ) -> DirectoryFrame? {
        guard descriptor >= 0 else {
            unreadable.append(path)
            return nil
        }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, FileID(opened) == FileID(information),
              opened.st_mode & S_IFMT == S_IFDIR, let stream = fdopendir(descriptor)
        else {
            close(descriptor)
            unreadable.append(path)
            return nil
        }
        return DirectoryFrame(directory: stream, descriptor: descriptor, path: path,
                              fileID: FileID(information), parent: parent)
    }

    private mutating func count(_ information: stat) {
        guard counted.insert(FileID(information)).inserted else { return }
        logical += max(0, Int64(information.st_size))
        allocated += max(0, Int64(information.st_blocks)) * 512
    }

    private func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                String(cString: $0)
            }
        }
    }

    private struct FileID: Hashable {
        let device: dev_t
        let inode: ino_t

        init(_ information: stat) {
            device = information.st_dev
            inode = information.st_ino
        }
    }

    private struct DirectoryFrame {
        let directory: UnsafeMutablePointer<DIR>
        let descriptor: Int32
        let path: String
        let fileID: FileID
        let parent: DirectoryParent?

        var isStillNamed: Bool {
            var current = stat()
            let result = if let parent {
                fstatat(parent.descriptor, parent.name, &current, AT_SYMLINK_NOFOLLOW)
            } else {
                lstat(path, &current)
            }
            return result == 0 && current.st_mode & S_IFMT == S_IFDIR && FileID(current) == fileID
        }
    }
}
