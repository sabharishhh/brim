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
                
                let measured = Self.measure(at: evidence.url, fm: fm)

                let capability = Self.determineCapability(for: evidence.url.path)

                localItems.append(FootprintItem(
                    evidence: evidence,
                    sizeBytes: measured.bytes,
                    capability: capability,
                    unreadableEntries: measured.unreadable
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
    
    /// What one location weighs, and what could not be read.
    ///
    /// Three things this gets right that the obvious version did not:
    ///
    /// - **A hardlink is one file, not two.** Counting each name separately
    ///   inflates a footprint by however many links a file has.
    ///   Deduplicated on device and inode.
    /// - **A symlink is the link, not its target.** `attributesOfItem` calls
    ///   `stat`, so sizing a symlink that points at a 10 GB file added 10 GB
    ///   that removing the link would never free. `lstat` measures the link
    ///   itself, which is the thing that goes.
    /// - **Unreadable is not empty.** Anything that cannot be read is
    ///   counted and reported rather than quietly contributing nothing. A
    ///   total that is short by an unknown amount and does not say so is
    ///   the failure this product exists to avoid.
    ///
    /// The figure is *logical*: what the files contain. It is not what
    /// removing them returns, which also depends on blocks shared with
    /// clones and blocks pinned by snapshots. `StorageAccountant` owns that
    /// distinction, and this number must never be shown as though it were
    /// the same one.
    struct Measurement: Sendable {
        var bytes: Int64 = 0
        var unreadable: Int = 0
    }

    nonisolated static func measure(at url: URL, fm: FileManager) -> Measurement {
        var result = Measurement()
        // Device and inode together, so two names for one file count once.
        var counted = Set<[UInt64]>()

        func add(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                result.unreadable += 1
                return
            }
            // A directory's own size is an artefact of the directory
            // structure rather than content. A symlink counts as the few
            // bytes it actually is.
            guard (info.st_mode & S_IFMT) != S_IFDIR else { return }

            let key = [UInt64(info.st_dev), UInt64(info.st_ino)]
            guard counted.insert(key).inserted else { return }
            result.bytes += Int64(info.st_size)
        }

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return result }

        guard isDirectory.boolValue else {
            add(url.path)
            return result
        }

        let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, _ in
                // Keep walking. One unreadable subtree is a gap to report,
                // not a reason to abandon the measurement.
                result.unreadable += 1
                return true
            }
        )
        guard let enumerator else {
            result.unreadable += 1
            return result
        }

        while let entry = enumerator.nextObject() as? URL {
            add(entry.path)
        }
        return result
    }
}
