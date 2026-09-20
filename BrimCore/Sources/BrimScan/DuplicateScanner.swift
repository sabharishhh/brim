import Foundation
import CryptoKit
import Darwin
import BrimCore

public actor DuplicateScanner {
    
    public init() {}
    
    public func scan(directory: URL) async throws -> [DuplicateGroup] {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        
        var sizeMap: [Int64: [URL]] = [:]
        
        // 1. Size class grouping
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0 else {
                continue
            }
            
            sizeMap[Int64(size), default: []].append(url)
        }
        
        // Filter out unique sizes
        let duplicateCandidates = sizeMap.filter { $0.value.count > 1 }
        
        var results: [DuplicateGroup] = []
        
        for (size, urls) in duplicateCandidates {
            // 2. Sparse fingerprinting (head, tail)
            var sparseMap: [String: [URL]] = [:]
            
            for url in urls {
                let sparse = sparseFingerprint(url: url, size: size)
                sparseMap[sparse, default: []].append(url)
            }
            
            // 3. Full hash for survivors
            for (_, sparseUrls) in sparseMap where sparseUrls.count > 1 {
                var hashMap: [String: [URL]] = [:]
                
                for url in sparseUrls {
                    if let hash = fullHash(url: url) {
                        hashMap[hash, default: []].append(url)
                    }
                }
                
                // Finalize groups
                for (hash, exactUrls) in hashMap where exactUrls.count > 1 {
                    let recoverable = calculateRecoverableBytes(urls: exactUrls, size: size)
                    let group = DuplicateGroup(size: size, paths: exactUrls.map { $0.path }, hash: hash, recoverableBytes: recoverable)
                    results.append(group)
                }
            }
        }
        
        return results
    }
    
    private func sparseFingerprint(url: URL, size: Int64) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        
        // Disable caching so we don't blow out the page cache (T-5.4)
        _ = fcntl(fh.fileDescriptor, F_NOCACHE, 1)
        
        let chunk = 4096
        let headData = (try? fh.read(upToCount: chunk)) ?? Data()
        
        var tailData = Data()
        if size > Int64(chunk) {
            try? fh.seek(toOffset: UInt64(size) - UInt64(chunk))
            tailData = (try? fh.read(upToCount: chunk)) ?? Data()
        }
        
        var hasher = SHA256()
        hasher.update(data: headData)
        hasher.update(data: tailData)
        let digest = hasher.finalize()
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func fullHash(url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        
        // Disable caching on large one-shot passes
        _ = fcntl(fh.fileDescriptor, F_NOCACHE, 1)
        
        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1MB
        
        while let data = try? fh.read(upToCount: bufferSize), !data.isEmpty {
            hasher.update(data: data)
        }
        
        let digest = hasher.finalize()
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func calculateRecoverableBytes(urls: [URL], size: Int64) -> Int64 {
        // T-5.4: Exclude clone-linked pairs from the savings total and label them as already sharing storage.
        // For the deferred spike, we simulate clone detection by clustering on st_ino (hardlinks) 
        // and identifying APFS clones. Since exact clone detection without private APIs requires 
        // heuristics or `clonefile` attempts, we use `st_ino` for exact identity sharing for now.
        
        var uniqueInodes = Set<UInt64>()
        for url in urls {
            var statBuf = stat()
            if stat(url.path, &statBuf) == 0 {
                uniqueInodes.insert(statBuf.st_ino)
            }
        }
        
        // If everything is a clone/hardlink of the same inode, recoverable is 0.
        // Otherwise, if we have N unique inodes, we can recover N-1 copies.
        let distinctPhysicalCopies = max(1, uniqueInodes.count)
        return size * Int64(distinctPhysicalCopies - 1)
    }
}
