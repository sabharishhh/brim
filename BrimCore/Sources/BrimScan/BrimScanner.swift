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
    
    /// Recursively enumerates a directory without following symlinks or aliases.
    public func enumerate(url: URL) -> AsyncThrowingStream<ScanEntry, Error> {
        return AsyncThrowingStream { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try self.walk(url: url, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // Note: This is now a synchronous function running on a background DispatchQueue
    private func walk(url: URL, continuation: AsyncThrowingStream<ScanEntry, Error>.Continuation) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey, .contentModificationDateKey]
        
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants]) else {
            return
        }
        
        var childDirs: [URL] = []
        
        while let fileURL = enumerator.nextObject() as? URL {
            let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys))
            let isDir = resourceValues?.isDirectory ?? false
            let isSymlink = resourceValues?.isSymbolicLink ?? false
            let isAlias = resourceValues?.isAliasFile ?? false
            let size = Int64(resourceValues?.fileSize ?? 0)
            let modDate = resourceValues?.contentModificationDate ?? Date()
            
            let entry = ScanEntry(
                url: fileURL,
                isDirectory: isDir,
                isSymlink: isSymlink || isAlias,
                size: size,
                modificationDate: modDate
            )
            
            let yieldResult = continuation.yield(entry)
            if case .terminated = yieldResult { return }
            
            if isDir && !isSymlink && !isAlias {
                childDirs.append(fileURL)
            }
        }
        
        for childDir in childDirs {
            try walk(url: childDir, continuation: continuation)
        }
    }
}
