import Foundation
import BrimCore

/// Computes an on-demand, non-stored projection of an app's footprint on disk.
public struct FootprintProjector: Sendable {
    public let engine: EvidenceEngine
    
    public init(engine: EvidenceEngine) {
        self.engine = engine
    }
    
    /// Generates the footprint for an identity.
    /// Re-evaluates sizes and presence dynamically, fulfilling the "query, never a stored object" invariant.
    public func project(identity: Identity, in root: FileSystemRoot) async throws -> Footprint {
        let app = try await engine.discover(identity: identity, in: root)
        
        let fm = FileManager.default
        let items = await Task.detached {
            var localItems = [FootprintItem]()
            for evidence in app.evidence {
                guard fm.fileExists(atPath: evidence.url.path) else { continue }
                
                let size = Self.calculateSize(at: evidence.url, fm: fm)
                
                var capability: Capability = .ok
                if !fm.isWritableFile(atPath: evidence.url.path) {
                    capability = .needsHelper
                }
                
                localItems.append(FootprintItem(
                    evidence: evidence,
                    sizeBytes: size,
                    capability: capability
                ))
            }
            return localItems
        }.value
        
        return Footprint(identity: identity, items: items)
    }
    
    nonisolated private static func calculateSize(at url: URL, fm: FileManager) -> Int64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int64) ?? 0
        }
        
        // Deep size calculation for directories
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) else {
            return 0
        }
        
        var totalSize: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = resourceValues.fileSize {
                totalSize += Int64(size)
            }
        }
        
        return totalSize
    }
}
