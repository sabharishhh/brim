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

/// A failed step's `localizedDescription` is kept in the journal and shown
/// in the result, so each case says what happened.
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
