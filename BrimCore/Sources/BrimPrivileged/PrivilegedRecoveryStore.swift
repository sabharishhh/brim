import Darwin
import Foundation

public struct PrivilegedRecoveryItem: Codable, Sendable {
    public let identifier: String
    public let path: String
    public let name: String
    public let bundleID: String?
    public let sizeBytes: Int64
    public let sizeIsKnown: Bool
    public let dev: Int32
    public let ino: UInt64
    public let mtime: Date
}

/// Recovery is a fixed three-level store, never a caller-supplied deletion path.
struct PrivilegedRecoveryStore {
    let root: URL
    let expectedOwner: uid_t
    let checkAncestors: Bool
    static let entryLimit = 2000

    init() {
        root = URL(fileURLWithPath: BrimJobHelper.quarantineDirectory)
        expectedOwner = 0
        checkAncestors = true
    }

    /// Fixtures inject their own store; the daemon always uses the fixed root.
    init(root: URL, expectedOwner: uid_t) {
        self.root = root
        self.expectedOwner = expectedOwner
        checkAncestors = false
    }

    func items() throws -> [PrivilegedRecoveryItem] {
        let descriptor: Int32
        do {
            descriptor = try openRoot()
        } catch let error as POSIXError where error.code == .ENOENT {
            return []
        }
        defer { close(descriptor) }
        var budget = Self.entryLimit
        var result: [PrivilegedRecoveryItem] = []
        for stamp in try names(in: descriptor, budget: &budget) {
            let dated = try openDirectory(parent: descriptor, name: stamp)
            defer { close(dated) }
            for source in try names(in: dated, budget: &budget) {
                let folder = try openDirectory(parent: dated, name: source)
                defer { close(folder) }
                for name in try names(in: folder, budget: &budget) {
                    let info = try metadata(parent: folder, name: name)
                    let kind = info.st_mode & S_IFMT
                    guard kind == S_IFREG || kind == S_IFDIR || kind == S_IFLNK else {
                        throw refusal("The recovery folder contains an unsupported item.")
                    }
                    let identifier = [stamp, source, name].joined(separator: "/")
                    result.append(PrivilegedRecoveryItem(
                        identifier: identifier, path: root.appendingPathComponent(identifier).path,
                        name: name, bundleID: bundleID(parent: folder, name: name, kind: kind),
                        sizeBytes: kind == S_IFDIR ? 0 : Int64(info.st_size),
                        sizeIsKnown: kind != S_IFDIR, dev: info.st_dev, ino: info.st_ino,
                        mtime: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                            + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
                    ))
                }
            }
        }
        return result.sorted { $0.identifier < $1.identifier }
    }

    func remove(identifier: String, expectedDevice: Int32, expectedInode: UInt64) throws {
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts.allSatisfy(PrivilegedJobRemoval.isPlainName) else {
            throw refusal("That is not a recovery item identifier.")
        }
        let descriptor = try openRoot()
        defer { close(descriptor) }
        let dated = try openDirectory(parent: descriptor, name: parts[0])
        defer { close(dated) }
        let folder = try openDirectory(parent: dated, name: parts[1])
        defer { close(folder) }
        // Parent folders cannot be replaced by an unprivileged caller. The
        // final object must still be the one the person selected.
        let info = try metadata(parent: folder, name: parts[2])
        guard info.st_dev == expectedDevice, info.st_ino == expectedInode else {
            throw refusal("The recovery item changed. Refresh the list before removing it.")
        }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR || kind == S_IFLNK else {
            throw refusal("That recovery item cannot be removed.")
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent(identifier))
        var remaining = stat()
        guard fstatat(folder, parts[2], &remaining, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw refusal("The recovery item is still present.")
        }
    }

    private func openRoot() throws -> Int32 {
        guard checkAncestors else {
            let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw systemError() }
            do { try checkDirectory(descriptor); return descriptor } catch { close(descriptor); throw error }
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemError() }
        do {
            try checkDirectory(descriptor)
            for component in root.pathComponents.dropFirst() {
                let next = try openDirectory(parent: descriptor, name: component)
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private func openDirectory(parent: Int32, name: String) throws -> Int32 {
        guard PrivilegedJobRemoval.isPlainName(name) else { throw refusal("The recovery folder has an invalid name.") }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemError() }
        do { try checkDirectory(descriptor); return descriptor } catch { close(descriptor); throw error }
    }

    private func checkDirectory(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw systemError() }
        guard info.st_uid == expectedOwner, info.st_mode & 0o022 == 0 else {
            throw refusal("The recovery folder's ownership or permissions changed.")
        }
    }

    private func metadata(parent: Int32, name: String) throws -> stat {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw systemError() }
        return info
    }

    private func names(in descriptor: Int32, budget: inout Int) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw systemError() }
        guard let directory = fdopendir(copy) else { close(copy); throw systemError() }
        defer { closedir(directory) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." {
                continue
            }
            guard budget > 0 else {
                throw refusal("The recovery folder is too large to list in one request.")
            }
            budget -= 1
            guard PrivilegedJobRemoval.isPlainName(name) else {
                throw refusal("The recovery folder has an invalid name.")
            }
            result.append(name)
            errno = 0
        }
        guard errno == 0 else { throw systemError() }
        return result.sorted()
    }

    private func bundleID(parent: Int32, name: String, kind: mode_t) -> String? {
        // Set-aside bundles retain their original owner. Only the store's
        // parent directories must be root-owned; metadata reads never follow links.
        guard kind == S_IFDIR else { return nil }
        let bundle = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard bundle >= 0 else { return nil }
        defer { close(bundle) }
        let contents = openat(bundle, "Contents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard contents >= 0 else { return nil }
        defer { close(contents) }
        let descriptor = openat(contents, "Info.plist", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 64 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count == bytes.count,
              let plist = try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    private func systemError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func refusal(_ message: String) -> NSError {
        NSError(domain: "BrimRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
