import Foundation

/// A missing directory is a measured absence; a failed read is not.
enum DirectoryEntries {
    case absent
    case listed([String])
    case refused

    var isRefused: Bool {
        if case .refused = self {
            return true
        }
        return false
    }

    var isListed: Bool {
        if case .listed = self {
            return true
        }
        return false
    }

    static func read(_ directory: URL, using fileManager: FileManager = .default) -> Self {
        do {
            return try .listed(fileManager.contentsOfDirectory(atPath: directory.path).sorted())
        } catch {
            return isMissing(error) ? .absent : .refused
        }
    }

    static func isMissing(_ error: Error) -> Bool {
        let failure = error as NSError
        return (failure.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code))
            || (failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT))
    }
}
