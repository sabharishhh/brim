import Foundation

public struct TierSVetoEngine: Sendable {
    private let root: FileSystemRoot
    
    public init(root: FileSystemRoot) {
        self.root = root
    }
    
    public func applyVeto(to footprint: EvaluatedFootprint) async -> EvaluatedFootprint {
        var vettedItems = [EvaluatedItem]()
        
        for item in footprint.items {
            if case .selected = item.selection {
                let targetURL = item.footprintItem.evidence.url
                
                if let sharedWith = await checkSharedClaims(for: targetURL, identity: footprint.identity) {
                    vettedItems.append(EvaluatedItem(
                        footprintItem: item.footprintItem,
                        selection: .excluded(reason: "Shared file claimed by \(sharedWith.name)"),
                        costOfError: item.costOfError
                    ))
                    continue
                }
            }
            vettedItems.append(item)
        }
        
        return EvaluatedFootprint(
            identity: footprint.identity, items: vettedItems, completeness: footprint.completeness
        )
    }
    
    private func checkSharedClaims(for url: URL, identity: Identity) async -> Identity? {
        let path = url.path
        
        // 1. Group Containers Check
        if path.contains("Group Containers") {
            // In a real implementation we would scan other apps' Info.plist for com.apple.security.application-groups
        }
        
        // 2. Cross-identity resolution
        // If the path resolves to an identity that is NOT the footprint's identity, it is shared/owned by someone else
        let resolver = IdentityResolver(root: root)
        let resolved = await resolver.resolve(bundleURL: url)
        if let resolvedID = resolved.bundleID, let footprintID = identity.bundleID, resolvedID != footprintID {
            return resolved
        }
        
return nil
    }
}
