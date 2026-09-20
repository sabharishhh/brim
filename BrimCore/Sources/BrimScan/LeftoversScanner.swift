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
        let activeBundleIDs = await gatherActiveAppBundleIDs()
        let receiptBundleIDs = await gatherInstallerReceipts()
        
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
                let identifier = extractIdentifier(from: item, in: domain)
                guard let bundleID = identifier else { continue }
                
                // Skip Apple system stuff roughly
                if bundleID.hasPrefix("com.apple.") && !bundleID.hasPrefix("com.apple.logic") && !bundleID.hasPrefix("com.apple.FinalCut") {
                    continue
                }
                
                if activeBundleIDs.contains(bundleID) {
                    // Active app, not a leftover
                    continue
                }
                
                // Determine category
                let category: Leftover.Category
                if receiptBundleIDs.contains(bundleID) || knownPastBundleIDs.contains(bundleID) {
                    category = .orphaned
                } else {
                    category = .unclaimed
                }
                
                let size = calculateSize(url: item)
                
                let leftover = Leftover(
                    url: item,
                    size: size,
                    category: category,
                    potentialOwner: Identity(bundleID: bundleID, name: item.deletingPathExtension().lastPathComponent)
                )
                leftovers.append(leftover)
            }
        }
        
        // Return sorted by size descending as per Volume I (Unclaimed sorted by size)
        return leftovers.sorted { $0.size > $1.size }
    }
    
    private func scanDirectoryLevel1(_ url: URL) -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else {
            return []
        }
        return urls
    }
    
    private func extractIdentifier(from url: URL, in domain: FileSystemRoot.Domain) -> String? {
        let name = url.lastPathComponent
        if domain == .userPreferences {
            if name.hasSuffix(".plist") {
                return String(name.dropLast(6))
            }
            return nil
        }
        if domain == .userSavedApplicationState {
            if name.hasSuffix(".savedState") {
                return String(name.dropLast(11))
            }
            return nil
        }
        if domain == .userGroupContainers {
            // Group containers often start with TeamID. We'll just return the part after the dot if it exists, or the whole thing.
            // Actually, we'll return the whole name and let the active apps set contain it if possible, but group containers are hard to match to bundle IDs directly without entitlements.
            // For now, if we don't have a perfect match, it'll just be "unclaimed"
            return name
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
    
    private func gatherActiveAppBundleIDs() async -> Set<String> {
        var active = Set<String>()
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
                        if let bid = identity.bundleID {
                            active.insert(bid)
                        }
                    }
                }
            }
        }
        
        return active
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
