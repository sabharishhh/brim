import Foundation
import Darwin

public enum SafeOpsError: Error {
    case failedToOpenParent(Int32)
    case fingerprintMismatch
    case failedToStat(Int32)
    case failedToRename(Int32)
    case failedToUnlink(Int32)
    case crossDeviceLink
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
    
    /// Securely trashes an item.
    /// It attempts to rename the item securely into a temporary directory on the same volume,
    /// then uses NSWorkspace or FileManager to trash it or remove it safely.
    public static func trashItem(
        targetPath: String,
        expectedDev: Int32,
        expectedIno: UInt64
    ) throws {
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
        
        // 2. Perform the secure rename
        let destName = UUID().uuidString
        try renameSecurely(targetPath: targetPath, expectedDev: expectedDev, expectedIno: expectedIno, destFd: destFd, destName: destName)
        
        // 3. Now that it is in our secure isolated temp directory, we can safely delete or trash it recursively
        let isolatedURL = volumeURL.appendingPathComponent(destName)
        
        // For M1, we can just recursively delete it, or move to the actual Trash.
        // Let's move to Trash using FileManager since it's now in an isolated space.
        var resultingURL: NSURL? = nil
        try fm.trashItem(at: isolatedURL, resultingItemURL: &resultingURL)
    }
    
    /// Returns the free space in bytes on the volume containing the given path.
    public static func freeSpace(onPath path: String) throws -> Int64 {
        var statBuf = statfs()
        guard statfs(path, &statBuf) == 0 else {
            throw SafeOpsError.failedToStat(errno)
        }
        return Int64(statBuf.f_bavail) * Int64(statBuf.f_bsize)
    }
}
