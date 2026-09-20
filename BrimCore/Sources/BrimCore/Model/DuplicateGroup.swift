import Foundation

public struct DuplicateGroup: Sendable, Codable {
    public let size: Int64
    public let paths: [String]
    public let hash: String
    
    // Total logical size of this group
    public var logicalSize: Int64 {
        return size * Int64(paths.count)
    }
    
    // Space recoverable if we keep exactly 1 copy. 
    // Excludes clone-linked pairs or hardlinks that already share storage.
    public let recoverableBytes: Int64
    
    public init(size: Int64, paths: [String], hash: String, recoverableBytes: Int64) {
        self.size = size
        self.paths = paths
        self.hash = hash
        self.recoverableBytes = recoverableBytes
    }
}
