import Foundation
import BrimCore

public actor LeftoversScanner {
    public let root: FileSystemRoot
    private let resolver: IdentityResolver
    
    public init(root: FileSystemRoot) {
        self.root = root
        self.resolver = IdentityResolver(root: root)
    }
    
    public func scanLeftovers(knownPastBundleIDs: Set<String> = []) async throws -> [Leftover] {
        let activeIdentities = await gatherActiveAppIdentities()
        let receiptBundleIDs = await gatherInstallerReceipts()
        
        let activeBundleIDs = Set(activeIdentities.compactMap { $0.bundleID })
        let activeNames = Set(activeIdentities.map { $0.name.lowercased() })
        let activeGroupContainers = Set(activeIdentities.flatMap { $0.groupContainers })
        let activeTeamIDs = Set(activeIdentities.compactMap { $0.teamID })
        
        var leftovers: [Leftover] = []
        
        let domainsToScan: [FileSystemRoot.Domain] = [
            .userApplicationSupport,
            .userCaches,
            .userSavedApplicationState,
            .userLogs,
            .userWebKit,
            .userContainers,
            .userGroupContainers,
            .userPreferences
        ]
        
        for domain in domainsToScan {
            let dir = root.url(for: domain)
            let items = scanDirectoryLevel1(dir)
            for item in items {
                let name = item.lastPathComponent
                
                // Skip Apple system stuff roughly
                if name.hasPrefix("com.apple.") && !name.hasPrefix("com.apple.logic") && !name.hasPrefix("com.apple.FinalCut") {
                    continue
                }
                
                if isItemActive(item: item, in: domain, activeBundleIDs: activeBundleIDs, activeNames: activeNames, activeGroupContainers: activeGroupContainers, activeTeamIDs: activeTeamIDs) {
                    continue
                }
                
                let ownerID = extractOwnerIdentifier(from: item, in: domain)
                
                // Determine category
                let category: Leftover.Category
                if receiptBundleIDs.contains(ownerID) || knownPastBundleIDs.contains(ownerID) || receiptBundleIDs.contains(name) || knownPastBundleIDs.contains(name) {
                    category = .orphaned
                } else {
                    category = .unclaimed
                }
                
                let size = calculateSize(url: item)
                
                let leftover = Leftover(
                    url: item,
                    size: size,
                    category: category,
                    potentialOwner: Identity(bundleID: ownerID.contains(".") ? ownerID : nil, name: item.deletingPathExtension().lastPathComponent)
                )
                leftovers.append(leftover)
            }
        }
        
        // Return sorted by size descending as per Volume I (Unclaimed sorted by size)
        return leftovers.sorted { $0.size > $1.size }
    }
    
    private func isItemActive(
        item: URL,
        in domain: FileSystemRoot.Domain,
        activeBundleIDs: Set<String>,
        activeNames: Set<String>,
        activeGroupContainers: Set<String>,
        activeTeamIDs: Set<String>
    ) -> Bool {
        let name = item.lastPathComponent
        let lowerName = name.lowercased()
        
        switch domain {
        case .userGroupContainers:
            if activeGroupContainers.contains(name) { return true }
            for teamID in activeTeamIDs {
                if name.hasPrefix(teamID + ".") {
                    let suffix = String(name.dropFirst(teamID.count + 1))
                    if activeBundleIDs.contains(suffix) || activeNames.contains(suffix.lowercased()) {
                        return true
                    }
                }
            }
            if let dotIndex = name.firstIndex(of: ".") {
                let suffix = String(name[name.index(after: dotIndex)...])
                if activeBundleIDs.contains(suffix) || activeNames.contains(suffix.lowercased()) {
                    return true
                }
            }
            return false
            
        case .userApplicationSupport, .userCaches, .userLogs, .userWebKit, .userContainers:
            if activeBundleIDs.contains(name) { return true }
            if activeNames.contains(lowerName) { return true }
            if domain == .userContainers {
                if let base = name.split(separator: ".").last, activeNames.contains(base.lowercased()) {
                    return true
                }
            }
            return false
            
        case .userPreferences:
            let base = name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
            return activeBundleIDs.contains(base) || activeNames.contains(base.lowercased())
            
        case .userSavedApplicationState:
            let base = name.hasSuffix(".savedState") ? String(name.dropLast(11)) : name
            return activeBundleIDs.contains(base) || activeNames.contains(base.lowercased())
            
        default:
            return activeBundleIDs.contains(name) || activeNames.contains(lowerName)
        }
    }
    
    private func scanDirectoryLevel1(_ url: URL) -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else {
            return []
        }
        return urls
    }
    
    private func extractOwnerIdentifier(from url: URL, in domain: FileSystemRoot.Domain) -> String {
        let name = url.lastPathComponent
        if domain == .userPreferences && name.hasSuffix(".plist") {
            return String(name.dropLast(6))
        }
        if domain == .userSavedApplicationState && name.hasSuffix(".savedState") {
            return String(name.dropLast(11))
        }
        if domain == .userGroupContainers {
            if let dotIndex = name.firstIndex(of: ".") {
                return String(name[name.index(after: dotIndex)...])
            }
        }
        return name
    }
    
    private func calculateSize(url: URL) -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys) else {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int64) ?? 0
        }
        
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let res = try? fileURL.resourceValues(forKeys: Set(keys))
            if let size = res?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
    
    private func gatherActiveAppIdentities() async -> [Identity] {
        var identities = [Identity]()
        let fm = FileManager.default
        
        // 1. Applications
        let appDirs = [
            root.url(for: .applications),
            root.rootURL.appendingPathComponent("System/Applications"),
            root.rootURL.appendingPathComponent("Users/\(root.userName)/Applications")
        ]
        
        var searchRoots = appDirs
        
        // 2. Volumes
        if let volumes = try? fm.contentsOfDirectory(at: root.url(for: .volumes), includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for vol in volumes {
                searchRoots.append(vol.appendingPathComponent("Applications"))
                searchRoots.append(vol.appendingPathComponent("Users/\(root.userName)/Applications"))
            }
        }
        
        // 3. Readable users
        if let users = try? fm.contentsOfDirectory(at: root.url(for: .users), includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for user in users {
                searchRoots.append(user.appendingPathComponent("Applications"))
            }
        }
        
        for dir in searchRoots {
            if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants, .skipsHiddenFiles]) {
                let urls = enumerator.compactMap { $0 as? URL }
                for fileURL in urls {
                    if fileURL.pathExtension == "app" {
                        let identity = await resolver.resolve(bundleURL: fileURL)
                        identities.append(identity)
                    }
                }
            }
        }
        
        return identities
    }
    
    private func gatherInstallerReceipts() async -> Set<String> {
        var receipts = Set<String>()
        let fm = FileManager.default
        let receiptsDir = root.rootURL.appendingPathComponent("var/db/receipts")
        if let items = try? fm.contentsOfDirectory(at: receiptsDir, includingPropertiesForKeys: nil) {
            for item in items {
                if item.pathExtension == "plist" || item.pathExtension == "bom" {
                    let bid = item.deletingPathExtension().lastPathComponent
                    receipts.insert(bid)
                }
            }
        }
        return receipts
    }
}
