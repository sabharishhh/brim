import Foundation

public enum SafeOpsError: Error {
    case failedToOpenParent(Int32)
    case fingerprintMismatch
    case failedToStat(Int32)
    case failedToRename(Int32)
    case failedToUnlink(Int32)
    case crossDeviceLink
    case pathOccupied
}

/// A removal's journal keeps `localizedDescription` for a step that failed
/// and the result shows it, so each case says what happened. Without this
/// a changed file read "The operation couldn't be completed
/// (BrimOps.SafeOpsError error 1.)".
extension SafeOpsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .failedToOpenParent: "The folder holding it could not be opened."
        case .fingerprintMismatch: "It changed after the review, so Brim left it alone."
        case .failedToStat: "Brim could not read it."
        case .failedToRename: "macOS would not let Brim move it."
        case .failedToUnlink: "macOS would not let Brim delete it."
        case .crossDeviceLink: "It is on a different disk from where Brim keeps what it removes."
        case .pathOccupied: "Something else is already where it was."
        }
    }
}
