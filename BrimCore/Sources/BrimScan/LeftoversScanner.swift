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

    /// Registrations whose program has gone, keyed by the bundle they name.
    /// Supplied by the caller because enumerating them is the registration
    /// sweep's job, not this scanner's.
    private let staleRegistrationOwners: [String: String]
    /// Homebrew casks whose application is gone. A package manager's own
    /// record is exactly the kind of evidence that turns an unattributed
    /// folder into a named orphan, and nothing was reading it.
    private let homebrewOrphans: Set<String>

    public init(
        root: FileSystemRoot,
        launchServicesLookup: (@Sendable (String) -> [URL])? = nil,
        staleRegistrationOwners: [String: String] = [:],
        homebrewOrphans: Set<String> = [],
        hasFullDiskAccess: Bool? = nil
    ) {
        self.staleRegistrationOwners = staleRegistrationOwners
        self.homebrewOrphans = homebrewOrphans
        self.root = root
        self.resolver = IdentityResolver(root: root)
        self.launchServicesLookup = launchServicesLookup ?? { _ in [] }
        self.hasFullDiskAccess = hasFullDiskAccess ?? FullDiskAccessProbe.isGranted()
    }
    
    public func scanLeftovers(knownPastBundleIDs: Set<String> = []) async throws -> [Leftover] {
        let (activeIdentities, bundleNames) = await gatherActiveAppIdentities()
        let receiptBundleIDs = await gatherInstallerReceipts()

        let activeBundleIDs = Set(activeIdentities.compactMap { $0.bundleID })
        // The bundle's own `CFBundleName` as well as what the icon says,
        // because an application's support folder is named after the
        // former. Visual Studio Code calls itself Code in its
        // `Info.plist` and writes a hundred and thirty megabytes to
        // `Application Support/Code`, and the sweep was offering all of
        // it up while the application was installed and running.
        let activeNames = Set(activeIdentities.map { $0.name.lowercased() })
            .union(bundleNames.map { $0.lowercased() })
        let activeGroupContainers = Set(activeIdentities.flatMap { $0.groupContainers })
        let activeTeamIDs = Set(activeIdentities.compactMap { $0.teamID })
        
        let search = OwnershipSearch(
            installedBundleIDs: activeBundleIDs,
            installedNames: activeNames,
            receiptBundleIDs: receiptBundleIDs,
            previouslyRemovedBundleIDs: knownPastBundleIDs,
            staleRegistrationOwners: staleRegistrationOwners,
            launchServicesLookup: launchServicesLookup
        )

        var leftovers: [Leftover] = []
        
        // Driven by the same inventory the uninstall path uses, rather
        // than a second list kept by hand. The two had drifted: removing
        // an application looked in sixty places and sweeping for what
        // software left behind looked in eight, so /Library, every
        // installer receipt and every command line tool were invisible.
        let domainsToScan = LocationInventory.sweepDomains

        for domain in domainsToScan {
            let dir = root.url(for: domain)
            // A vendor folder puts its children on the queue in place of
            // itself, so the walk is one level deep and only where there
            // is a reason to go deeper.
            var queue: [(url: URL, vendor: String?)] =
                scanDirectoryLevel1(dir).map { ($0, nil) }
            var cursor = 0
            while cursor < queue.count {
                let (item, vendor) = queue[cursor]
                cursor += 1
                let name = item.lastPathComponent
                /// The name to reason about: `Chrome` inside `Google` is
                /// `Google Chrome`, which is what the application is
                /// actually called and the only spelling that matches it.
                let qualified = vendor.map { "\($0) \(name)" } ?? name

                // Apple's own data is never the user's to clean up, and the
                // prefix check has to survive the group-container spelling:
                // a group container is named `group.com.apple.SHTTS`, which
                // does not start with `com.apple.` and so was being listed
                // as a leftover — one of them had been written to under a
                // minute before the scan.
                //
                // Logic and Final Cut are the deliberate exceptions: Apple
                // ships them separately, they can genuinely be uninstalled,
                // and their support folders are the largest leftovers on
                // many machines.
                if Self.isAppleOwned(name) { continue }

                // Folders in the system domain that macOS itself put
                // there. They are not named after a bundle, so the
                // reverse-DNS test above never sees them, and offering to
                // remove /Library/Application Support/Apple would be a
                // serious thing to get wrong.
                if Self.isSystemOwnedByName(name, in: domain) { continue }

                // A link is judged by what it points at, never by its
                // name, and that answer arrives before any of the rest.
                switch Self.symlink(item) {
                case .some(.resolved):
                    continue
                case .some(.dangling(let target)):
                    leftovers.append(Self.brokenLink(item, pointingAt: target))
                    continue
                case nil:
                    break
                }

                if isItemActive(item: item, in: domain, vendor: vendor, activeBundleIDs: activeBundleIDs, activeNames: activeNames, activeGroupContainers: activeGroupContainers, activeTeamIDs: activeTeamIDs) {
                    continue
                }

                // A folder shared between one vendor's products answers
                // nothing about any of them. Its children do.
                if vendor == nil,
                   let children = vendorFolderChildren(
                       item, in: domain, activeNames: activeNames
                   ) {
                    queue.append(contentsOf: children.map { ($0, name) })
                    continue
                }

                let ownerID = extractOwnerIdentifier(from: item, in: domain)

                // The whole search, in one place: an item is only a leftover
                // once every source that could name an owner has come back
                // without one. The identifier and the directory name are both
                // tried, because not every domain is named after the bundle.
                let verdict = [ownerID, name, qualified]
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

                // Homebrew's own record, before settling for "nobody
                // claims this". A cask Homebrew still lists, whose
                // application is not on the disk, names the owner of
                // anything carrying its name, which is the difference
                // between a row that says "2BBY89MBSN.dev.warp" and one
                // that says Warp.
                let cask = Self.matchingOrphanedCask(
                    ownerID: ownerID, name: qualified, among: homebrewOrphans
                )

                let category: Leftover.Category
                let evidence: String
                if let cask {
                    category = .orphaned
                    evidence = "Homebrew still lists the cask \(cask), and its application is "
                             + "not installed."
                } else if let settled = verdict.category {
                    category = settled
                    if case .recordedButGone(let sentence) = verdict {
                        evidence = sentence
                    } else {
                        evidence = "Nothing installed claims this, and no record remembers "
                                 + "what put it here."
                    }
                } else {
                    continue
                }

                let size = calculateSize(url: item)

                // An empty folder nobody can name gives back nothing and
                // says nothing. Two hundred and forty-one of them turn a
                // list somebody has to read into one they scroll past,
                // which is how a real finding gets missed. An empty
                // folder that *is* named stays, because then it is
                // evidence of something.
                //
                // Only folders. This used to drop anything measuring
                // zero, and a file's size was being measured with a
                // directory enumerator, which answers zero for every
                // file there is. Preference plists went straight through
                // it, which is to say the most ordinary leftover on a
                // Mac was the one thing the sweep could not report.
                if size == 0, category != .orphaned, Self.isDirectory(item) { continue }

                let leftover = Leftover(
                    url: item,
                    size: size,
                    category: category,
                    potentialOwner: Identity(
                        bundleID: ownerID.contains(".") ? ownerID : nil,
                        name: cask?.capitalized
                            ?? Self.readableName(ownerID: ownerID, url: item, qualified: qualified)
                    ),
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
    
    /// Whether a directory belongs to macOS itself.
    ///
    /// Whether a plainly-named entry in a system folder belongs to macOS.
    ///
    /// `/Library` holds Apple's own work under ordinary names: `Apple`,
    /// `BTServer`, `iLifeMediaBrowser`, `DiagnosticReports`. Nothing
    /// about those names says Apple, so the reverse-DNS test misses them
    /// entirely, and a sweep that offered them as leftovers would be
    /// offering to break the system.
    ///
    /// The rule is narrow on purpose: in a system folder, an entry is a
    /// candidate only when it is named like a bundle identifier, which is
    /// how third-party installers name what they leave there. Apple's
    /// plainly-named folders and anything else unrecognisable stay out.
    /// `jp.co.nikon.UninstallCenter.Receipts` is a leftover;
    /// `iLifeMediaBrowser` is macOS.
    static func isSystemOwnedByName(_ name: String, in domain: FileSystemRoot.Domain) -> Bool {
        let systemDomains: Set<FileSystemRoot.Domain> = [
            .systemApplicationSupport, .systemCaches, .systemLogs,
            .systemPreferences, .systemContainers, .systemDiagnosticReports,
            .systemServices, .systemQuickLook, .systemSpotlight, .systemAutomator,
            .systemColorPickers, .systemScreenSavers, .systemInternetPlugIns,
            .systemPreferencePanes, .systemExtensionsFolder, .startupItems,
        ]
        guard systemDomains.contains(domain) else { return false }

        // Named like a bundle identifier: at least two dot-separated
        // parts, and the first is a domain-ish token.
        let base = name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
        let parts = base.split(separator: ".")
        return parts.count < 3
    }

    /// Matches both `com.apple.x` and the group-container form
    /// `group.com.apple.x`, and the bare `group.com.apple` prefix used by
    /// several system group containers.
    static func isAppleOwned(_ name: String) -> Bool {
        let identifier = name.hasPrefix("group.") ? String(name.dropFirst("group.".count)) : name
        guard identifier.hasPrefix("com.apple.") || identifier == "com.apple" else { return false }
        // Separately shipped, separately removable, and often the biggest
        // leftovers on the machine.
        return !identifier.hasPrefix("com.apple.logic")
            && !identifier.hasPrefix("com.apple.FinalCut")
    }

    // MARK: - Symbolic links

    enum LinkVerdict {
        /// Points at something that is there, so it belongs to whatever
        /// that is.
        case resolved
        /// Points at something that has gone.
        case dangling(target: URL)
    }

    /// What a symbolic link is, decided by its target rather than its name.
    ///
    /// `/usr/local/bin` is almost entirely links into application
    /// bundles, and a name match there answers nothing: `code` is Visual
    /// Studio Code's, `python3` is the framework's, `kubectl` is
    /// Docker's. Where the link points answers it exactly.
    ///
    /// A link whose target is still there is that target's business and
    /// not a leftover. A link whose target has gone is among the
    /// cleanest leftovers there is: a command still on the PATH that
    /// cannot run. Several of them on the machine this was written on,
    /// left by an uninstalled Docker and Zed, and Brim reported none of
    /// them, because a link measures zero bytes and the sweep was
    /// throwing away everything that measured zero.
    static func symlink(_ url: URL) -> LinkVerdict? {
        let manager = FileManager.default
        guard let destination = try? manager.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }
        let target = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : url.deletingLastPathComponent().appendingPathComponent(destination)
        let resolved = target.standardizedFileURL
        return manager.fileExists(atPath: resolved.path)
            ? .resolved
            : .dangling(target: resolved)
    }

    static func brokenLink(_ url: URL, pointingAt target: URL) -> Leftover {
        let owner = ownerOfPath(target)
        return Leftover(
            url: url,
            size: 0,
            category: .orphaned,
            potentialOwner: Identity(bundleID: nil, name: owner ?? url.lastPathComponent),
            evidence: owner.map {
                "This command points into \($0), which is not installed."
            } ?? "This command points at \(target.path), which is not there.",
            capability: .ok,
            lastAccessed: nil
        )
    }

    /// The application or framework a path runs through, if any.
    ///
    /// `/Applications/Docker.app/Contents/Resources/bin/docker` is
    /// Docker's whatever the command at the end is called, and saying
    /// Docker is the difference between a row somebody understands and a
    /// row saying `kubectl.docker`.
    static func ownerOfPath(_ url: URL) -> String? {
        for component in url.pathComponents {
            if component.hasSuffix(".app") || component.hasSuffix(".framework") {
                return component
            }
        }
        return nil
    }

    // MARK: - Vendor folders

    /// Domains where one folder can hold several products.
    ///
    /// Settings and saved state are keyed by identifier, one file each,
    /// so there is nothing below them to descend into. Support, caches
    /// and logs are where a vendor makes a folder of its own and puts
    /// each product inside it.
    static let nestable: Set<FileSystemRoot.Domain> = [
        .userApplicationSupport, .systemApplicationSupport,
        .userCaches, .systemCaches,
        .userLogs, .systemLogs,
        .sharedUser, .sharedApplicationSupport,
    ]

    /// The children to judge in place of this folder, when the folder is
    /// one vendor's and holds more than one product.
    ///
    /// The evidence for calling something a vendor folder is narrow on
    /// purpose: an installed application is called `<this folder> <something
    /// else>`. `Google` qualifies while Google Chrome is installed,
    /// because "Google" is how Chrome's name begins and is not the whole
    /// of it. `Obsidian` never qualifies, so its subfolders of profile
    /// data are never offered up one by one. Getting that backwards
    /// turns a single honest row into many wrong ones.
    ///
    /// Without this, `~/Library/Application Support/Google/DeadProduct`
    /// is invisible: the sweep sees `Google`, finds Chrome behind it,
    /// and walks away from everything else in there.
    func vendorFolderChildren(
        _ url: URL, in domain: FileSystemRoot.Domain, activeNames: Set<String>
    ) -> [URL]? {
        guard Self.nestable.contains(domain), Self.isDirectory(url) else { return nil }
        let name = url.lastPathComponent.lowercased()
        guard !name.isEmpty else { return nil }
        let prefix = name + " "
        guard activeNames.contains(where: { $0.hasPrefix(prefix) && $0.count > prefix.count })
        else { return nil }
        let children = scanDirectoryLevel1(url)
        return children.isEmpty ? nil : children
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func isItemActive(
        item: URL,
        in domain: FileSystemRoot.Domain,
        vendor: String?,
        activeBundleIDs: Set<String>,
        activeNames: Set<String>,
        activeGroupContainers: Set<String>,
        activeTeamIDs: Set<String>
    ) -> Bool {
        let name = item.lastPathComponent
        let lowerName = name.lowercased()

        // Inside a vendor folder the application's real name is the two
        // put together, and some installers write it with a dot instead.
        if let vendor {
            if activeNames.contains("\(vendor) \(name)".lowercased()) { return true }
            if activeBundleIDs.contains("\(vendor).\(name)") { return true }
        }

        switch domain {
        case .userGroupContainers, .userApplicationScripts:
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
            
        case .userPreferencesByHost:
            // com.example.app.<hardware uuid>.plist, so the domain is
            // everything before the identifier.
            var base = name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
            let parts = base.split(separator: ".")
            if parts.count > 1, UUID(uuidString: String(parts[parts.count - 1])) != nil {
                base = parts.dropLast().joined(separator: ".")
            }
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
    
    /// Which orphaned cask, if any, this item belongs to.
    ///
    /// Matched on a whole component rather than a substring: `warp`
    /// against `dev.warp` is a match, `warp` against `warpdrive` is not.
    /// A loose match here would put somebody else's data under a name
    /// that had nothing to do with it.
    static func matchingOrphanedCask(
        ownerID: String, name: String, among casks: Set<String>
    ) -> String? {
        guard !casks.isEmpty else { return nil }
        let components = Set(
            (ownerID + "." + name)
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
        return casks.first { cask in
            let normalised = cask.lowercased()
            if components.contains(normalised) { return true }
            // Homebrew hyphenates: boring-notch against boringnotch.
            let squashed = normalised.filter { $0.isLetter || $0.isNumber }
            return components.contains(squashed)
        }
    }

    /// Something a person can read, instead of a team identifier and a
    /// reverse-DNS name.
    static func readableName(ownerID: String, url: URL, qualified: String? = nil) -> String {
        // Inside a vendor folder the vendor is half the name, and
        // dropping it leaves a row saying "Chrome" beside one saying
        // "Updater" with nothing to connect them.
        if let qualified, qualified != url.lastPathComponent { return qualified }
        let candidate = ownerID.isEmpty
            ? url.deletingPathExtension().lastPathComponent : ownerID
        // The last meaningful component: dev.warp becomes Warp,
        // com.example.app becomes App.
        let parts = candidate.split(separator: ".")
        guard let last = parts.last, parts.count > 1 else { return candidate }
        return String(last).capitalized
    }

    private func extractOwnerIdentifier(from url: URL, in domain: FileSystemRoot.Domain) -> String {
        let name = url.lastPathComponent
        if domain == .userPreferences && name.hasSuffix(".plist") {
            return String(name.dropLast(6))
        }
        if domain == .userSavedApplicationState && name.hasSuffix(".savedState") {
            return String(name.dropLast(11))
        }
        // Both are named <teamID>.<bundle id>, so the owner is what
        // follows the team.
        if domain == .userGroupContainers || domain == .userApplicationScripts {
            if let dotIndex = name.firstIndex(of: ".") {
                return String(name[name.index(after: dotIndex)...])
            }
        }
        if domain == .userPreferencesByHost, name.hasSuffix(".plist") {
            var base = String(name.dropLast(6))
            let parts = base.split(separator: ".")
            if parts.count > 1, UUID(uuidString: String(parts[parts.count - 1])) != nil {
                base = parts.dropLast().joined(separator: ".")
            }
            return base
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

    /// What removing this would give back.
    ///
    /// A directory enumerator over a plain file yields nothing and
    /// answers zero, which is how every preference plist on the machine
    /// came back weightless. A file is asked for its own size, and a
    /// symbolic link is worth nothing and is never followed: measuring
    /// through one credits a command with the size of the application it
    /// points at.
    private func calculateSize(url: URL) -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        if values?.isSymbolicLink == true { return 0 }
        if values?.isDirectory == false { return Int64(values?.fileSize ?? 0) }

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
    
    /// Every installed application's identity, plus the name each
    /// bundle uses for itself internally.
    ///
    /// `Identity.name` is the bundle's file name, `VisualStudioCode.app`
    /// becomes "VisualStudioCode". Its `CFBundleName` is what it names
    /// its own support folder after, and Visual Studio Code's is
    /// "Code". Reading only the file name left `Application Support/Code`
    /// looking unclaimed while the application sat in `/Applications`.
    private func gatherActiveAppIdentities() async -> (identities: [Identity], bundleNames: [String]) {
        var identities = [Identity]()
        var bundleNames = [String]()
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
                        if let bundle = Bundle(url: fileURL),
                           let bundleName = bundle.infoDictionary?["CFBundleName"] as? String,
                           !bundleName.isEmpty {
                            bundleNames.append(bundleName)
                        }
                    }
                }
            }
        }

        return (identities, bundleNames)
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
