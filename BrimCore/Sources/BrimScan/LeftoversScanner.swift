import Foundation
import BrimCore

public actor LeftoversScanner {
    public let root: FileSystemRoot
    private let resolver: IdentityResolver
    /// Launch Services' answer for a bundle identifier. Injected so the
    /// ownership rules can be tested without depending on what happens to be
    /// installed on the machine running the suite.
    private let launchServicesLookup: @Sendable (String) -> [URL]
    /// Whether this process can reach protected locations, which decides
    /// whether a container leftover is removable or only visible.
    private let hasFullDiskAccess: Bool

    public init(
        root: FileSystemRoot,
        launchServicesLookup: (@Sendable (String) -> [URL])? = nil,
        hasFullDiskAccess: Bool? = nil
    ) {
        self.root = root
        self.resolver = IdentityResolver(root: root)
        self.launchServicesLookup = launchServicesLookup ?? { _ in [] }
        self.hasFullDiskAccess = hasFullDiskAccess ?? FullDiskAccessProbe.isGranted()
    }
    
    public func scanLeftovers(knownPastBundleIDs: Set<String> = []) async throws -> [Leftover] {
        let activeIdentities = await gatherActiveAppIdentities()
        let receiptBundleIDs = await gatherInstallerReceipts()
        
        let activeBundleIDs = Set(activeIdentities.compactMap { $0.bundleID })
        let activeNames = Set(activeIdentities.map { $0.name.lowercased() })
        let activeGroupContainers = Set(activeIdentities.flatMap { $0.groupContainers })
        let activeTeamIDs = Set(activeIdentities.compactMap { $0.teamID })
        
        let search = OwnershipSearch(
            installedBundleIDs: activeBundleIDs,
            installedNames: activeNames,
            receiptBundleIDs: receiptBundleIDs,
            previouslyRemovedBundleIDs: knownPastBundleIDs,
            launchServicesLookup: launchServicesLookup
        )

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

                // The whole search, in one place: an item is only a leftover
                // once every source that could name an owner has come back
                // without one. The identifier and the directory name are both
                // tried, because not every domain is named after the bundle.
                let verdict = [ownerID, name]
                    .map(search.ownership(of:))
                    .reduce(Ownership.unattributable) { strongest, next in
                        switch (strongest, next) {
                        case (.present, _): return strongest
                        case (_, .present): return next
                        case (.recordedButGone, _): return strongest
                        case (_, .recordedButGone): return next
                        default: return strongest
                        }
                    }

                guard let category = verdict.category else { continue }
                let evidence: String
                if case .recordedButGone(let sentence) = verdict {
                    evidence = sentence
                } else {
                    evidence = "No application on any mounted volume or readable account "
                             + "claims this, and macOS has no record of one. Brim cannot say "
                             + "what put it here."
                }

                let leftover = Leftover(
                    url: item,
                    size: calculateSize(url: item),
                    category: category,
                    potentialOwner: Identity(bundleID: ownerID.contains(".") ? ownerID : nil, name: item.deletingPathExtension().lastPathComponent),
                    evidence: evidence,
                    capability: capability(for: item, in: domain),
                    lastAccessed: lastAccessed(of: item)
                )
                leftovers.append(leftover)
            }
        }
        
        // Sorted by size descending. Access time is carried on each item and
        // may be used to order them, but never to argue that something is
        // disposable: nothing having read a file lately says nothing about
        // whether its owner is gone.
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
    
    /// Whether Brim can remove this, rather than only see it.
    ///
    /// A sandbox container carries a `containermanagerd` metadata file that
    /// cannot be unlinked without Full Disk Access — and not by `sudo`
    /// either, since TCC is judged on the responsible application rather
    /// than the effective user. Reported honestly so the UI can explain it
    /// instead of failing.
    private func capability(for url: URL, in domain: FileSystemRoot.Domain) -> Capability {
        switch domain {
        case .userContainers, .userGroupContainers:
            return hasFullDiskAccess ? .ok : .needsFullDiskAccess
        default:
            return .ok
        }
    }

    private func lastAccessed(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
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
