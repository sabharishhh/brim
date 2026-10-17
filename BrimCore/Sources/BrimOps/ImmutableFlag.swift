import Foundation

/// The lock that makes a file refuse to be deleted. `UF_IMMUTABLE` is
/// Finder's "Locked" and its owner can clear it; `SF_IMMUTABLE` needs root
/// and SIP's permission. Detecting which is `ArtifactLock` in `BrimCore`;
/// this is the half that changes the file, and `ImmutableFlagAgreementTests`
/// holds the two to one answer.
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

    /// Takes the user lock off one file, having checked it is the same file:
    /// opened without following links, and its device and inode checked against
    /// the plan.
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

        // `O_SYMLINK` opens a link as itself; `O_NOFOLLOW` alone would fail on one.
        let descriptor = open(path, O_RDONLY | O_SYMLINK)
        guard descriptor >= 0 else {
            // A file with no read permission has its flags cleared through the path,
            // the only option left.
            guard lchflags(path, info.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 else {
                throw ClearError.refused(code: errno)
            }
            return
        }
        defer { close(descriptor) }

        // Re-check through the descriptor, so what is unlocked is what was
        // inspected.
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
