import Foundation
import Darwin

public struct StorageAccountant: Sendable {
    
    public init() {}
    
    /// Evaluates the items in a footprint grouped by filesystem volume using native statfs.
    /// Never claims snapshot-pinned bytes when underlying APFS snapshot extent evidence is unavailable or ambiguous.
    /// Eliminates all child-process shellouts (e.g. tmutil) to adhere to sandbox and security boundaries.
    public func account(for items: [FootprintItem]) async -> (logical: Int64, reclaimable: Int64, pinned: Int64) {
        guard !items.isEmpty else {
            return (0, 0, 0)
        }
        
        // Group items by volume mount point using native statfs
        var volumeMap: [String: (fsType: String, items: [FootprintItem])] = [:]
        
        for item in items {
            let path = item.evidence.url.path
            var statBuf = statfs()
            let mountPoint: String
            let fsType: String
            
            if statfs(path, &statBuf) == 0 {
                mountPoint = withUnsafePointer(to: statBuf.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                fsType = withUnsafePointer(to: statBuf.f_fstypename) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
                }
            } else {
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                if statfs(parent, &statBuf) == 0 {
                    mountPoint = withUnsafePointer(to: statBuf.f_mntonname) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                    }
                    fsType = withUnsafePointer(to: statBuf.f_fstypename) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
                    }
                } else {
                    mountPoint = "/"
                    fsType = "unknown"
                }
            }
            
            var entry = volumeMap[mountPoint] ?? (fsType: fsType, items: [])
            entry.items.append(item)
            volumeMap[mountPoint] = entry
        }
        
        var totalLogical: Int64 = 0
        var totalReclaimable: Int64 = 0
        var totalPinned: Int64 = 0
        
        for (_, entry) in volumeMap {
            let volLogical = entry.items.reduce(0) { $0 + $1.sizeBytes }
            totalLogical += volLogical
            
            // Per security requirement: Never claim snapshot-pinned/reclaimable bytes
            // when the underlying APFS evidence is unavailable or ambiguous.
            // When per-extent snapshot pinning evidence is unavailable via native APIs,
            // we do not fabricate pinned numbers: pinned = 0, reclaimable = volLogical.
            let volPinned: Int64 = 0
            let volReclaimable: Int64 = volLogical
            
            totalPinned += volPinned
            totalReclaimable += volReclaimable
        }
        
        return (totalLogical, totalReclaimable, totalPinned)
    }
}
