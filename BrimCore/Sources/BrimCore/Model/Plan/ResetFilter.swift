import Foundation

public struct ResetFilter {
    /// Filters a footprint for a `.reset` plan.
    /// Preserves the .app bundle, launchd plists, receipts, group containers, and suspected license files.
    /// Returns a tuple of (itemsToDelete, excludedItems).
    public static func filter(footprint: Footprint) -> (itemsToDelete: [FootprintItem], excludedItems: [ExcludedItem]) {
        var toDelete: [FootprintItem] = []
        var excluded: [ExcludedItem] = []
        
        for item in footprint.items {
            let path = item.evidence.url.path
            let name = item.evidence.url.lastPathComponent.lowercased()
            
            // 1. Preserve the main .app bundle
            if path.hasSuffix(".app") || path.hasSuffix(".app/") {
                excluded.append(ExcludedItem(target: path, reason: "Preserved main application bundle for reset"))
                continue
            }
            
            // 2. Preserve Launch Services / Receipts
            if path.contains("/Library/LaunchAgents/") || path.contains("/Library/LaunchDaemons/") {
                excluded.append(ExcludedItem(target: path, reason: "Preserved Launchd job for reset"))
                continue
            }
            if path.hasSuffix(".bom") || path.hasSuffix(".plist") && path.contains("/var/db/receipts/") {
                excluded.append(ExcludedItem(target: path, reason: "Preserved installer receipt for reset"))
                continue
            }
            
            // 3. Preserve Group Containers (Shared state/keychain often lives here)
            if item.evidence.mechanism == "GroupContainerSource" || item.evidence.mechanism == "TeamIDSource" {
                excluded.append(ExcludedItem(target: path, reason: "Preserved Group Container (potential shared state/keychains) for reset"))
                continue
            }
            
            // 4. Preserve License heuristics
            if name.contains("license") || name.contains("activation") || name.contains("serial") || name.contains("key") {
                excluded.append(ExcludedItem(target: path, reason: "Preserved suspected license or activation material for reset"))
                continue
            }
            
            // Otherwise, queue for deletion
            toDelete.append(item)
        }
        
        return (toDelete, excluded)
    }
}
