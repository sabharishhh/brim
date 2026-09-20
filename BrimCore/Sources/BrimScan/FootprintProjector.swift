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
    public func project(identity: Identity, in root: FileSystemRoot, explicitEvidence: [Evidence]? = nil) async throws -> Footprint {
        let evidenceList: [Evidence]
        if let explicit = explicitEvidence {
            evidenceList = explicit
        } else {
            let app = try await engine.discover(identity: identity, in: root)
            evidenceList = app.evidence
        }
        
        let fm = FileManager.default
        let items = await Task.detached {
            var localItems = [FootprintItem]()
            for evidence in evidenceList {
                guard fm.fileExists(atPath: evidence.url.path) else { continue }
                
                let size = Self.calculateSize(at: evidence.url, fm: fm)
                
                let capability = Self.determineCapability(for: evidence.url.path)
                
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
    
    
    nonisolated private static func determineCapability(for path: String) -> Capability {
        if access(path, W_OK) == 0 {
            return .ok
        }
        
        let err = errno
        
        var statInfo = stat()
        if stat(path, &statInfo) == 0 {
            let SF_RESTRICTED: UInt32 = 0x00080000
            if (statInfo.st_flags & SF_RESTRICTED) != 0 {
                return .refusedByOS
            }
        } else {
            if errno == EPERM {
                return .needsFullDiskAccess
            }
        }
        
        if err == EPERM {
            return .needsFullDiskAccess
        } else if err == EACCES {
            return .needsHelper
        }
        
        return .needsHelper
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
