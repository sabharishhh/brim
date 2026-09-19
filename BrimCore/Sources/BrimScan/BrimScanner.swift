import Foundation
import BrimScanShim
import BrimCore

public struct ScanEntry: Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let size: Int64
    public let modificationDate: Date
}

public struct BrimScanner: Sendable {
    
    public init() {}
    
    /// Recursively enumerates a directory without following symlinks.
    public func enumerate(url: URL) -> AsyncThrowingStream<ScanEntry, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await walk(url: url, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    private func walk(url: URL, continuation: AsyncThrowingStream<ScanEntry, Error>.Continuation) async throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants]) else {
            return
        }
        
        var childDirs: [URL] = []
        
        while let fileURL = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            
            let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys))
            let isDir = resourceValues?.isDirectory ?? false
            let isSymlink = resourceValues?.isSymbolicLink ?? false
            let size = Int64(resourceValues?.fileSize ?? 0)
            let modDate = resourceValues?.contentModificationDate ?? Date()
            
            let entry = ScanEntry(
                url: fileURL,
                isDirectory: isDir,
                isSymlink: isSymlink,
                size: size,
                modificationDate: modDate
            )
            
            continuation.yield(entry)
            
            if isDir && !isSymlink {
                childDirs.append(fileURL)
            }
        }
        
        for childDir in childDirs {
            try await walk(url: childDir, continuation: continuation)
        }
    }
}
