import Foundation
import Darwin

public enum SafeOpsError: Error {
    case failedToOpenParent(Int32)
    case fingerprintMismatch
    case failedToStat(Int32)
    case failedToRename(Int32)
    case failedToUnlink(Int32)
    case crossDeviceLink
    case pathOccupied
}

public struct SafeOps {
    
    /// Securely removes or relocates an item by opening its parent directory and using the `*at` family of syscalls.
    /// - Parameters:
    ///   - targetPath: The absolute path to the item.
    ///   - expectedDev: The expected device ID from the plan's fingerprint.
    ///   - expectedIno: The expected inode from the plan's fingerprint.
    ///   - destFd: A file descriptor to a secure temporary directory (opened with O_DIRECTORY).
    ///   - destName: The name to give the file in the destination directory.
    public static func renameSecurely(
        targetPath: String,
        expectedDev: Int32,
        expectedIno: UInt64,
        destFd: Int32,
        destName: String
    ) throws {
        let targetURL = URL(fileURLWithPath: targetPath)
        let parentPath = targetURL.deletingLastPathComponent().path
        let itemName = targetURL.lastPathComponent
        
        // Open parent directory, disallowing symlinks
        let parentFd = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentFd >= 0 else {
            throw SafeOpsError.failedToOpenParent(errno)
        }
        defer { close(parentFd) }
        
        try verifyParentDescriptor(parentFd, expectedPath: parentPath)
        
        // Stat the item relative to parent using AT_SYMLINK_NOFOLLOW
        var statBuf = stat()
        let statResult = fstatat(parentFd, itemName, &statBuf, AT_SYMLINK_NOFOLLOW)
        guard statResult == 0 else {
            throw SafeOpsError.failedToStat(errno)
        }
        
        // Verify fingerprint
        guard statBuf.st_dev == expectedDev && statBuf.st_ino == expectedIno else {
            throw SafeOpsError.fingerprintMismatch
        }
        
        // Rename the item into the secure destination
        let renameResult = renameat(parentFd, itemName, destFd, destName)
        guard renameResult == 0 else {
            let err = errno
            if err == EXDEV {
                throw SafeOpsError.crossDeviceLink
            }
            throw SafeOpsError.failedToRename(err)
        }
    }
    
    /// Securely verifies that a target path matches expectedDev and expectedIno using parent-fd fstatat without following symlinks.
    public static func verifyTargetFingerprint(
        targetPath: String,
        expectedDev: Int32,
        expectedIno: UInt64
    ) throws {
        let targetURL = URL(fileURLWithPath: targetPath)
        let parentPath = targetURL.deletingLastPathComponent().path
        let itemName = targetURL.lastPathComponent
        
        let parentFd = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentFd >= 0 else {
            throw SafeOpsError.failedToOpenParent(errno)
        }
        defer { close(parentFd) }
        
        try verifyParentDescriptor(parentFd, expectedPath: parentPath)
        
        var statBuf = stat()
        let statResult = fstatat(parentFd, itemName, &statBuf, AT_SYMLINK_NOFOLLOW)
        guard statResult == 0 else {
            throw SafeOpsError.failedToStat(errno)
        }
        
        guard statBuf.st_dev == expectedDev && statBuf.st_ino == expectedIno else {
            throw SafeOpsError.fingerprintMismatch
        }
    }
    
    /// Securely trashes an item.
    ///
    /// The item is renamed into an isolated directory on the same volume
    /// first, so a path swapped between the fingerprint check and the move
    /// cannot redirect this at something else. That rename uses a UUID, and
    /// the item is then given its **original name back** before it reaches
    /// the Trash — otherwise the user opens the Trash and finds a pile of
    /// opaque identifiers they cannot recognise, which makes "recoverable"
    /// true only on paper.
    ///
    /// Finder's own "Put Back" still will not work: macOS records where an
    /// item came from at the moment it is trashed, and by then it came from
    /// the isolated directory. Restoring is Brim's job — the journal records
    /// the trashed URL against the planned target, and `undo` uses that.
    public static func trashItem(
        targetPath: String,
        expectedDev: Int32,
        expectedIno: UInt64
    ) throws -> URL? {
        let targetURL = URL(fileURLWithPath: targetPath)
        // 1. Create a secure temp directory on the same volume (for renameat to work without EXDEV)
        let fm = FileManager.default
        let volumeURL = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: targetURL, create: true)
        defer { try? fm.removeItem(at: volumeURL) }
        
        let destFd = open(volumeURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard destFd >= 0 else {
            throw SafeOpsError.failedToOpenParent(errno)
        }
        defer { close(destFd) }
        try verifyParentDescriptor(destFd, expectedPath: volumeURL.path)
        
        // 2. Perform the secure rename
        let destName = UUID().uuidString
        try renameSecurely(targetPath: targetPath, expectedDev: expectedDev, expectedIno: expectedIno, destFd: destFd, destName: destName)
        
        // 3. Now that it is in our secure isolated temp directory, we can safely delete or trash it recursively
        let isolatedURL = volumeURL.appendingPathComponent(destName)

        // 4. Give it its name back before trashing. The item is already
        // unreachable by its original path, so nothing can be substituted
        // here — and the Trash needs to show "Photoshop.app", not a UUID.
        let originalName = targetURL.lastPathComponent
        var toTrash = isolatedURL
        if Self.isUsableTrashName(originalName) {
            let namedURL = volumeURL.appendingPathComponent(originalName)
            // The isolation directory is created fresh for this one item, so
            // there is nothing to collide with; if the rename fails anyway,
            // trashing under the UUID still beats not trashing at all.
            if (try? fm.moveItem(at: isolatedURL, to: namedURL)) != nil {
                toTrash = namedURL
            }
        }

        // Move to Trash using FileManager since the item is now in an isolated temp space.
        #if DEBUG
        if let stand = Self.standInTrash() {
            // Its own name, in a directory of its own. The real Trash
            // disambiguates by appending a time, and a test that checks the
            // name survives has to see the same thing here.
            let slot = stand.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: slot, withIntermediateDirectories: true)
            let landing = slot.appendingPathComponent(toTrash.lastPathComponent)
            try fm.moveItem(at: toTrash, to: landing)
            return landing
        }
        #endif
        var resultingURL: NSURL? = nil
        try fm.trashItem(at: toTrash, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    #if DEBUG
    /// Where a test's trashed items land instead of the user's Trash.
    ///
    /// `FileManager.trashItem` always means the real Trash, so a test that
    /// exercised the executor put its fixtures there: 58 bundles one
    /// session, 68 another, with Launch Services records to match. The
    /// harness is meant to leave nothing behind, and the only way to keep
    /// that promise is for the tests not to reach the real Trash at all.
    ///
    /// Detected rather than configured, so no test has to remember to opt
    /// in, and compiled out of a release build entirely.
    nonisolated(unsafe) private static var standInTrashURL: URL?
    private static let standInTrashLock = NSLock()

    static func standInTrash() -> URL? {
        guard NSClassFromString("XCTestCase") != nil else { return nil }
        standInTrashLock.lock()
        defer { standInTrashLock.unlock() }
        if let existing = standInTrashURL { return existing }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brim-test-trash-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        standInTrashURL = url
        return url
    }
    #endif

    /// Whether a basename can safely be used as a filename in the isolation
    /// directory. Rejects anything that would escape it or name the directory
    /// itself rather than an item inside it.
    public static func isUsableTrashName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.utf8.contains(0)
    }
    
    /// Securely and permanently removes an item.
    ///
    /// Same discipline as `trashItem`: verify the fingerprint, rename into an
    /// isolated directory on the same volume, and only then destroy it — so a
    /// path swapped between the check and the removal cannot redirect this at
    /// something else. There is no Trash copy afterwards, which is exactly why
    /// the isolation matters more here than it does for trashing.
    public static func deleteItem(
        targetPath: String,
        expectedDev: Int32,
        expectedIno: UInt64
    ) throws {
        let targetURL = URL(fileURLWithPath: targetPath)
        let fm = FileManager.default

        let isolationURL = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: targetURL, create: true)
        defer { try? fm.removeItem(at: isolationURL) }

        let destFd = open(isolationURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard destFd >= 0 else {
            throw SafeOpsError.failedToOpenParent(errno)
        }
        defer { close(destFd) }
        try verifyParentDescriptor(destFd, expectedPath: isolationURL.path)

        let destName = UUID().uuidString
        try renameSecurely(targetPath: targetPath, expectedDev: expectedDev, expectedIno: expectedIno, destFd: destFd, destName: destName)

        // Now isolated and unreachable by its original path, so removing it
        // cannot follow a symlink planted at the target.
        let isolatedURL = isolationURL.appendingPathComponent(destName)
        do {
            try fm.removeItem(at: isolatedURL)
        } catch {
            throw SafeOpsError.failedToUnlink(errno)
        }
    }

    /// Securely restores an item from the Trash to its original location.
    /// Opens the parent directory of the destination with O_NOFOLLOW | O_DIRECTORY
    /// and uses renameat to prevent symlink attacks.
    public static func restoreItem(
        from sourcePath: String,
        to destPath: String
    ) throws {
        let destURL = URL(fileURLWithPath: destPath)
        let parentURL = destURL.deletingLastPathComponent()
        
        let parentFd = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentFd >= 0 else {
            throw SafeOpsError.failedToOpenParent(errno)
        }
        defer { close(parentFd) }
        try verifyParentDescriptor(parentFd, expectedPath: parentURL.path)
        
        // Ensure source exists and is what we think it is
        if renameatx_np(AT_FDCWD, sourcePath, parentFd, destURL.lastPathComponent, UInt32(RENAME_EXCL)) != 0 {
            let err = errno
            if err == EEXIST {
                // DEBUG
                print("EEXIST for \(destPath). Let's see what's in there:")
                if let enumerator = FileManager.default.enumerator(atPath: parentURL.path) {
                    for item in enumerator { print(item) }
                }
                throw SafeOpsError.pathOccupied
            }
            if err == EXDEV {
                throw SafeOpsError.crossDeviceLink
            }
            throw SafeOpsError.failedToRename(err)
        }
    }
    
    /// Returns the free space in bytes on the volume containing the given path.
    public static func freeSpace(onPath path: String) throws -> Int64 {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        
        // Fallback to statfs
        var statBuf = statfs()
        guard statfs(path, &statBuf) == 0 else {
            throw SafeOpsError.failedToStat(errno)
        }
        return Int64(statBuf.f_bavail) * Int64(statBuf.f_bsize)
    }

    /// Verifies that an opened directory descriptor matches the expected parent path,
    /// accounting strictly for standard macOS root symlinks (/var, /tmp, /etc -> /private/...)
    /// and rejecting any unexpected intermediate symlink diversions.
    private static func verifyParentDescriptor(_ fd: Int32, expectedPath: String) throws {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else {
            throw SafeOpsError.failedToOpenParent(errno)
        }
        let resolvedPath = String(cString: buffer)
        
        if expectedPath == resolvedPath {
            return
        }
        
        // On macOS, /var, /tmp, and /etc are system-level symlinks to /private/var, /private/tmp, /private/etc.
        // We only allow /private prefixing if the expected path specifically targets these known system roots.
        let isSystemPrivateSymlink = expectedPath.hasPrefix("/var/") || expectedPath == "/var" ||
                                     expectedPath.hasPrefix("/tmp/") || expectedPath == "/tmp" ||
                                     expectedPath.hasPrefix("/etc/") || expectedPath == "/etc"
        
        if isSystemPrivateSymlink {
            let prefixed = "/private" + expectedPath
            if prefixed == resolvedPath {
                return
            }
        } else if expectedPath.hasPrefix("/private/") {
            let stripped = String(expectedPath.dropFirst("/private".count))
            if stripped == resolvedPath {
                return
            }
        }
        
        throw SafeOpsError.failedToOpenParent(ELOOP)
    }
}
