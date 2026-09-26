import Foundation

/// A missing directory is a measured absence; a failed read is not.
enum DirectoryEntries {
    case absent
    case listed([String])
    case refused

    static func read(_ directory: URL, using fileManager: FileManager = .default) -> Self {
        do {
            return try .listed(fileManager.contentsOfDirectory(atPath: directory.path).sorted())
        } catch {
            let failure = error as NSError
            let missingFile = failure.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)
            if missingFile {
                return .absent
            }
            if failure.domain == NSPOSIXErrorDomain, failure.code == Int(ENOENT) {
                return .absent
            }
            return .refused
        }
    }
}
