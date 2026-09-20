import Foundation

public struct ResetFilter {
    /// Filters a footprint for a `.reset` plan.
    /// Preserves the main application bundle/binary, background services/launchd registrations,
    /// installer receipts, group containers (shared state/keychains), credentials, and licensing material.
    /// Deletes only mutable state (caches, saved state, temporary data, logs, preferences).
    /// Returns a tuple of (itemsToDelete, excludedItems).
    public static func filter(footprint: Footprint) -> (itemsToDelete: [FootprintItem], excludedItems: [ExcludedItem]) {
        var toDelete: [FootprintItem] = []
        var excluded: [ExcludedItem] = []
        
        for item in footprint.items {
            let path = item.evidence.url.path
            let name = item.evidence.url.lastPathComponent.lowercased()
            let mechanism = item.evidence.mechanism
            
            // 1. Preserve the main application bundle or executable
            if mechanism == "AppBundleSource" || path.hasSuffix(".app") || path.hasSuffix(".app/") {
                excluded.append(ExcludedItem(target: path, reason: "Preserved main application bundle for reset"))
                continue
            }
            
            // 2. Preserve Launch Services / Background Registrations / SMAppService
            if mechanism == "LaunchdSource" || mechanism == "SMAppServiceSource" || mechanism == "LaunchServicesSource" ||
               path.contains("/Library/LaunchAgents/") || path.contains("/Library/LaunchDaemons/") {
                excluded.append(ExcludedItem(target: path, reason: "Preserved background launch registration for reset"))
                continue
            }
            
            // 3. Preserve Installer Receipts
            if mechanism == "InstallerReceiptSource" || path.hasSuffix(".bom") || (path.hasSuffix(".plist") && path.contains("/var/db/receipts/")) {
                excluded.append(ExcludedItem(target: path, reason: "Preserved installer receipt for reset"))
                continue
            }
            
            // 4. Preserve Group Containers (Shared state and shared keychains live here)
            if mechanism == "GroupContainerSource" || mechanism == "TeamIDSource" || path.contains("/Library/Group Containers/") {
                excluded.append(ExcludedItem(target: path, reason: "Preserved Group Container (shared state/keychains) for reset"))
                continue
            }
            
            // 5. Preserve Keychains and Security credentials
            if path.contains("/Keychains/") || name.contains("keychain") {
                excluded.append(ExcludedItem(target: path, reason: "Preserved keychain and security credential material for reset"))
                continue
            }
            
            // 6. Preserve Licensing and activation material
            if name.contains("license") || name.contains("activation") || name.contains("serial") ||
               name.hasSuffix(".lic") || name.contains("registration") || name.contains("reginfo") {
                excluded.append(ExcludedItem(target: path, reason: "Preserved licensing and activation material for reset"))
                continue
            }
            
            // Otherwise, mutable application state queued for reset deletion
            toDelete.append(item)
        }
        
        return (toDelete, excluded)
    }
}
