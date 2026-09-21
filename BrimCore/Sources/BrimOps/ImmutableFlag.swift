import Foundation

/// The lock that makes a file refuse to be deleted.
///
/// macOS has two of these and they are not interchangeable. `UF_IMMUTABLE`
/// is the one Finder calls "Locked": the owner sets it and the owner can
/// clear it. `SF_IMMUTABLE` is the system one, which only root can clear
/// and only while System Integrity Protection permits it at all.
///
/// Brim used to treat both the same way: `SafetyChecker` refused to remove
/// anything immutable and said nothing about why, so a locked file simply
/// went missing from the plan. "Did not look" is not "nothing found", and
/// neither is "would not touch".
///
/// Telling the two apart is `ArtifactLock` in `BrimCore`, because the
/// planner needs to ask before it can offer to unlock anything. This is
/// the half that changes the file, and
/// `ImmutableFlagAgreementTests` holds them to the same answer.
public enum ImmutableFlag {

    public enum ClearError: Error, LocalizedError, Equatable {
        case notThere
        /// The file changed identity between the plan and the attempt.
        case targetChanged
        case systemLocked
        case refused(code: Int32)

        public var errorDescription: String? {
            switch self {
            case .notThere:
                return "There is nothing at that path to unlock."
            case .targetChanged:
                return "The file at that path is not the one Brim planned to unlock, so it "
                     + "stopped."
            case .systemLocked:
                return "macOS locked this one, not you, and it stays locked."
            case .refused(let code):
                return "macOS would not unlock it: \(String(cString: strerror(code)))."
            }
        }
    }

    /// Takes the user lock off one file, having checked it is the same file.
    ///
    /// Opened with `O_NOFOLLOW` and `O_SYMLINK` so a symlink swapped in
    /// after the plan was made cannot redirect this onto something else,
    /// and the device and inode are checked against what was planned. The
    /// same discipline as every other mutating operation in this module.
    public static func clear(
        atPath path: String, expectedDev: Int32, expectedIno: UInt64
    ) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw ClearError.notThere }
        guard info.st_dev == expectedDev, info.st_ino == expectedIno else {
            throw ClearError.targetChanged
        }
        guard (info.st_flags & UInt32(SF_IMMUTABLE)) == 0 else {
            throw ClearError.systemLocked
        }

        // O_SYMLINK so a symlink is opened as itself rather than followed;
        // O_NOFOLLOW alone would fail on one instead.
        let descriptor = open(path, O_RDONLY | O_SYMLINK)
        guard descriptor >= 0 else {
            // A file with no read permission still has its flags cleared
            // through the path, which cannot be raced the same way but is
            // the only option left.
            guard lchflags(path, info.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 else {
                throw ClearError.refused(code: errno)
            }
            return
        }
        defer { close(descriptor) }

        // Re-check through the descriptor: what is unlocked is what was
        // inspected, not whatever the path points at by now.
        var confirmed = stat()
        guard fstat(descriptor, &confirmed) == 0,
              confirmed.st_dev == expectedDev, confirmed.st_ino == expectedIno else {
            throw ClearError.targetChanged
        }
        guard fchflags(descriptor, confirmed.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 else {
            throw ClearError.refused(code: errno)
        }
    }
}
