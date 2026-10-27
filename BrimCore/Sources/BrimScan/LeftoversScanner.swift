import BrimCore
import Darwin
import Foundation

// swiftformat:disable wrapMultilineStatementBraces

public actor LeftoversScanner {
    public let root: FileSystemRoot
    private let resolver: IdentityResolver
    /// Launch Services' answer for a bundle identifier, injected so the rules
    /// can be tested without depending on what is installed.
    private let launchServicesLookup: @Sendable (String) throws -> [URL]
    /// Whether this process can reach protected locations, which decides
    /// whether a container leftover is removable or only visible.
    private let hasFullDiskAccess: Bool
    /// A matching executable protects command line tool data in dot folders.
    private let commandIsInstalled: @Sendable (String) -> Bool
    /// Names actually present in the sealed system Library on this Mac.
    /// Gathered once per scan, before the domain tasks start.
    private let systemLibraryNames: Set<String>
    /// The reverse-DNS families macOS ships under, such as `org.cups`.
    private let systemFamilies: Set<String>
    /// The actual running Brim bundle may be a development build outside
    /// /Applications. It is still an installed owner of its own files.
    private let protectedAppURL: URL?

    /// Registrations whose program has gone, keyed by the bundle they name.
    /// Supplied by the caller; finding them is the registration sweep's job.
    private let staleRegistrationOwners: [String: String]
    /// Homebrew casks whose application is gone: a package manager's record
    /// names the owner of an otherwise unattributed folder.
    private let homebrewOrphans: Set<String>
    /// Paths Developer already accounts for, so they are not counted twice.
    private let claimedPaths: Set<String>
    /// Applications Brim's snapshots saw installed that have since gone,
    /// by bundle identifier, with when each was last seen.
    private let removedApplications: [String: Date]
    /// How recently something must have written to a folder no record names
    /// for it to count as in use. Nil reads nothing into it.
    private let inUseWithin: TimeInterval?

    public init(
        root: FileSystemRoot,
        launchServicesLookup: (@Sendable (String) throws -> [URL])? = nil,
        staleRegistrationOwners: [String: String] = [:],
        homebrewOrphans: Set<String> = [],
        claimedPaths: Set<String> = [],
        removedApplications: [String: Date] = [:],
        protectedAppURL: URL? = nil,
        hasFullDiskAccess: Bool? = nil,
        commandIsInstalled: (@Sendable (String) -> Bool)? = nil,
        inUseWithin: TimeInterval? = nil
    ) {
        self.inUseWithin = inUseWithin
        self.staleRegistrationOwners = staleRegistrationOwners
        self.homebrewOrphans = homebrewOrphans
        self.removedApplications = Dictionary(
            removedApplications.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: max
        )
        self.claimedPaths = Set(claimedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        self.root = root
        resolver = IdentityResolver(root: root)
        self.launchServicesLookup = launchServicesLookup ?? { _ in [] }
        self.hasFullDiskAccess = hasFullDiskAccess ?? FullDiskAccessProbe.isGranted()
        self.commandIsInstalled = commandIsInstalled ?? Self.defaultCommandLookup(in: root)
        systemLibraryNames = Self.systemNames(in: root)
        systemFamilies = Self.families(of: systemLibraryNames)
        self.protectedAppURL = protectedAppURL
    }

    public func scanLeftovers(
        knownPastBundleIDs: Set<String> = [], knownNames: [String: String] = [:],
        knownAliases: [String: [String]] = [:], knownIdentities: [Identity] = []
    ) async throws -> [Leftover] {
        try Task.checkCancellation()
        let gathered = await gatherActiveAppIdentities()
        try Task.checkCancellation()
        var gatheredIdentities = gathered.identities
        if let protectedAppURL, FileManager.default.fileExists(atPath: protectedAppURL.path) {
            let own = await resolver.resolve(bundleURL: protectedAppURL)
            gatheredIdentities.append(own)
            // Identifiers older builds shipped under; their preferences and caches
            // still belong to this running application.
            for oldID in SafetyChecker.identifiersOlderBuildsUsed {
                gatheredIdentities.append(Identity(bundleID: oldID, name: own.name))
            }
        }
        let activeIdentities = gatheredIdentities
        let receiptBundleIDs = await gatherInstallerReceipts()

        let activeBundleIDs = Set(activeIdentities.flatMap(\.searchBundleIdentifiers))
        // Every name an installed app answers to, `CFBundleName` included, from
        // `Identity`, so the sweep and the uninstall agree. Visual Studio Code
        // writes to `Application Support/Code`.
        let activeNames = Set(activeIdentities.flatMap { $0.searchNames.map { $0.lowercased() } })
        let activeGroupContainers = Set(activeIdentities.flatMap(\.searchGroupContainers))
        let activeTeamIDs = Set(activeIdentities.compactMap(\.teamID))
        let pastIdentities = Self.pastIdentities(
            knownPastBundleIDs, names: knownNames, aliases: knownAliases, identities: knownIdentities
        )

        let search = OwnershipSearch(
            installedBundleIDs: activeBundleIDs,
            installedNames: activeNames,
            receiptBundleIDs: receiptBundleIDs,
            previouslyRemovedBundleIDs: knownPastBundleIDs,
            staleRegistrationOwners: staleRegistrationOwners,
            launchServicesLookup: launchServicesLookup
        )

        // The same inventory the uninstall uses, so the two look in the same places.
        let domainsToScan = LocationInventory.sweepDomains

        // What installed applications wrote, by macOS's own record, so their data
        // is never offered while they run. The domains are walked in parallel
        // below: each reads its own tree and shares only values fixed before the
        // walk, which is what makes that safe. Results are sorted, so the answer
        // never depends on which domain finished first.
        let writers = ProvenanceSource.owners(of: activeIdentities)
        let vendors = SystemVendors(
            installed: activeIdentities, recorded: knownNames, past: pastIdentities,
            packageFolders: InstalledBundleInventory.packageInstallFolders(in: root), root: root
        )
        let prepared = Prepared(active: activeIdentities, past: pastIdentities,
                                activeBundleIDs: activeBundleIDs, root: root)
        let batches = try await BoundedTasks.map(domainsToScan) { [self] domain in
            walkDomain(domain, search, activeIdentities, pastIdentities,
                       activeBundleIDs, activeNames,
                       activeGroupContainers, activeTeamIDs, prepared, writers, knownNames, vendors)
        }
        let found = batches.flatMap(\.self)
        let leftovers = Self.markingVendors(
            Self.protectUncertainOwnership(found, complete: gathered.complete), installed: activeBundleIDs
        )

        // Sorted by size. Access time may order items but never argues something is
        // disposable.
        return leftovers.sorted { $0.size > $1.size }
    }

    /// Names the developer of each unclaimed item when nothing from that
    /// developer is installed, so their leftovers are one group rather than
    /// a row per product too small to be listed (`Leftover.vendor`).
    static func markingVendors(_ items: [Leftover], installed: Set<String>) -> [Leftover] {
        let installedVendors = Set(installed.compactMap { OwnerNamespace.vendor(for: $0) })
        return items.map { item in
            guard item.category == .unclaimed, let vendor = OwnerNamespace.vendor(for: item.url.lastPathComponent),
                  !installedVendors.contains(vendor) else { return item }
            var marked = item
            marked.vendor = vendor
            return marked
        }
    }

    private static func protectUncertainOwnership(_ items: [Leftover], complete: Bool) -> [Leftover] {
        guard !complete else { return items }
        return items.map { item in
            Leftover(url: item.url, size: item.size, category: .unclaimed,
                     potentialOwner: item.potentialOwner,
                     evidence: "Installed ownership could not be fully checked.",
                     capability: item.capability, lastAccessed: item.lastAccessed,
                     sizeIsKnown: item.sizeIsKnown != false)
        }
    }

    // The safety checks here must run before attributing or offering a path.
    // swiftlint:disable cyclomatic_complexity function_body_length
    private nonisolated func walkDomain(
        _ domain: FileSystemRoot.Domain,
        _ search: OwnershipSearch,
        _: [Identity],
        _ pastIdentities: [Identity],
        _ activeBundleIDs: Set<String>,
        _ activeNames: Set<String>,
        _ activeGroupContainers: Set<String>,
        _ activeTeamIDs: Set<String>,
        _ prepared: Prepared,
        _ writers: [ProvenanceSource.Owner],
        _ knownNames: [String: String],
        _ vendors: SystemVendors
    ) -> [Leftover] {
        var leftovers: [Leftover] = []
        let locationRules = LocationInventory.standard.locations.filter { $0.domain == domain }
        let ownerLookup = OwnerLookup(
            domain: domain, locationRules: locationRules,
            pastIdentities: pastIdentities,
            pastSubjects: prepared.pastSubjects, search: search
        )
        let activeSubjects = prepared.activeSubjects
        let containerClaimants = prepared.containerClaimants
        let installed = prepared.installed
        let inventoryRoots = prepared.inventoryRoots
        do {
            let dir = root.url(for: domain)
            // A vendor folder queues its children in its place, so the walk goes one
            // level deeper only where there is a reason.
            var queue: [(url: URL, vendor: String?)] =
                scanDirectoryLevel1(dir, hidden: domain == .userHomeDotFolders).map { ($0, nil) }
            var cursor = 0
            while cursor < queue.count {
                let (item, vendor) = queue[cursor]
                cursor += 1
                // A parent domain can contain another inventory root.
                // Its contents are scanned under their own rule; offering
                // the root itself would claim the whole subtree is residue.
                if inventoryRoots.contains(item.resolvingSymlinksInPath().path)
                    || claimedPaths.contains(item.standardizedFileURL.path) {
                    continue
                }
                let name = item.lastPathComponent
                let containerOwnership = domain == .userContainers || domain == .systemContainers
                    ? ContainerOwnershipReader.read(at: item) : nil
                // Every recorded claimant protects a container, even when
                // its records disagree about which app is the owner.
                if let ownership = containerOwnership, ownership.identifiers.contains(where: { owner in
                    Self.isAppleOwned(owner) || containerClaimants.contains {
                        owner.lowercased() == $0 || owner.lowercased().hasPrefix($0 + ".")
                    }
                }) {
                    continue
                }
                // The rest of the home folder is the person's own.
                if domain == .userHomeDotFolders, !name.hasPrefix(".") {
                    continue
                }
                // The name to reason about: `Chrome` inside `Google` is `Google Chrome`,
                // what the app is called.
                let qualified = vendor.map { "\($0) \(name)" } ?? name

                // Apple's own data is never the person's to clean up, including group
                // containers named `group.com.apple.*`. Logic and Final Cut are the
                // exceptions: Apple ships them separately and they can be uninstalled.
                if Self.isAppleOwned(name) || Self.isInstalledSystemComponent(name, names: systemLibraryNames) {
                    continue
                }

                // A name in a family macOS ships, such as CUPS's `org.cups.*`, on which the
                // printer list depends.
                if Self.isInSystemFamily(name, families: systemFamilies) {
                    continue
                }

                // A bundle says whose it is in its `Info.plist` and signature, which
                // outranks its file name.
                let signed = Self.bundleSignature(of: item)
                if let signed, Self.belongsToInstalledSoftware(
                    identifier: signed.identifier, team: signed.team, activeTeams: activeTeamIDs
                ) {
                    continue
                }

                // Folders in the system domain that macOS put there, which are not named
                // for a bundle, so the reverse-DNS test above cannot see them. Unless a
                // third party is known by that name (`Microsoft` in `/Library/Logs`): a
                // developer's folder is judged by what it holds and is never offered
                // itself. A bundle is judged by the identifier it declares, not its name.
                if vendor == nil, signed?.identifier == nil, containerOwnership?.identifier == nil,
                   Self.isSystemOwnedByName(name, in: domain) {
                    switch vendors.claim(name) {
                    case .application?:
                        break
                    case .developer?:
                        if Self.nestable.contains(domain), Self.isDirectory(item) {
                            queue.append(contentsOf: scanDirectoryLevel1(item).map { ($0, name) })
                        }
                        continue
                    case nil:
                        continue
                    }
                }

                // macOS moves files it could not migrate during an update into marked
                // folders under `/Users/Shared`. They are the person's, not residue.
                if domain == .sharedUser, Self.isMacOSRelocationFolder(item) {
                    continue
                }

                // A link is judged by what it points at, before anything else. Only a
                // command's missing target means anything; Chromium keeps locks as links
                // to tokens that never exist as files.
                switch Self.symlink(item) {
                case .some(.resolved):
                    continue
                case let .some(.dangling(target)) where Self.commandFolders.contains(domain):
                    leftovers.append(Self.brokenLink(item, pointingAt: target))
                    continue
                case .some(.dangling), nil:
                    break
                }

                let containerOwner = containerOwnership?.identifier

                // An installed app's claim comes first, before the developer-folder test,
                // or a folder an installed app uses could be opened as a developer's.
                let belongsToInstalledApp = isItemActive(
                    item: item, in: domain, vendor: vendor,
                    containerOwner: containerOwner,
                    locationRules: locationRules, installed: installed,
                    activeSubjects: activeSubjects,
                    activeBundleIDs: activeBundleIDs, activeNames: activeNames,
                    activeGroupContainers: activeGroupContainers, activeTeamIDs: activeTeamIDs,
                    writers: writers
                )
                if belongsToInstalledApp {
                    continue
                }

                // A developer's folder in the person's Library is judged by what it holds,
                // as in /Library.
                if vendor == nil, signed?.identifier == nil, Self.nestable.contains(domain),
                   !Self.systemDomains.contains(domain), vendors.claim(name) == .developer, Self.isDirectory(item) {
                    queue.append(contentsOf: scanDirectoryLevel1(item).map { ($0, name) })
                    continue
                }

                // A folder called `Caches` or `Logs` inside a place apps keep things is
                // someone's container, not an owner's name.
                if vendor == nil, Self.nestable.contains(domain),
                   Self.containerNames.contains(name.lowercased()), Self.isDirectory(item) {
                    queue.append(contentsOf: scanDirectoryLevel1(item).map { ($0, nil) })
                    continue
                }

                // A folder shared between one vendor's products answers
                // nothing about any of them. Its children do.
                if vendor == nil, let children = vendorFolderChildren(item, in: domain, activeNames: activeNames) {
                    queue.append(contentsOf: children.map { ($0, name) })
                    continue
                }

                let owner: ResolvedOwner
                if let uncertainty = containerOwnership?.uncertainty {
                    owner = ResolvedOwner(category: .unclaimed, evidence: uncertainty, ownerID: "", cask: nil)
                } else {
                    guard let resolved = resolvedOwner(
                        for: item, name: name, qualified: qualified,
                        containerOwner: containerOwner, declared: signed?.identifier, lookup: ownerLookup
                    ) else { continue }
                    owner = resolved
                }

                // Inside a developer's folder in a system location, anything no gone
                // product is named in may be shared (an updater, a licence) and stays while
                // any of that developer's software is installed. A folder holding a file
                // macOS names for itself is macOS's, whatever the folder is called.
                if owner.category == .unclaimed, Self.holdsApplesOwnFile(item) {
                    continue
                }
                // Where a name is all there is, only a record of an app that has gone names
                // an owner. An unclaimed dot folder or crash report says nothing about
                // whose it is.
                if Self.recordOnlyDomains.contains(domain), owner.category != .orphaned {
                    continue
                }
                // Nothing names it and something wrote to it this week, so it belongs to
                // something alive, not a removed app. Recent writing only ever keeps a
                // folder out; it never argues one is a leftover.
                if owner.category == .unclaimed, let window = inUseWithin,
                   Self.newestWrite(in: item).map({ Date().timeIntervalSince($0) < window }) == true {
                    continue
                }

                // Protected by macOS for itself: nobody's leftover, and nobody can remove
                // it.
                if RemovalCapability.isProtectedBySystem(item.path) {
                    continue
                }

                var evidence = owner.evidence
                if let vendor, Self.systemDomains.contains(domain), owner.category == .unclaimed {
                    guard !vendors.hasInstalled(vendor) else { continue }
                    evidence = "In \(vendor)'s folder. Nothing from \(vendor) is installed."
                }

                let measured = ArtifactSizer.measure(at: item)
                let size = measured.logicalBytes
                if let limitation = measured.completeness.explanation {
                    evidence += " " + limitation
                }

                // An empty folder nobody can name frees nothing and says nothing, and
                // hundreds of them bury real findings. A named empty folder stays, as
                // evidence. Folders only: files are measured by `lstat`, and a preferences
                // file is the most ordinary leftover there is.
                if measured.isEmpty, owner.category != .orphaned, Self.isDirectory(item) {
                    continue
                }

                let leftover = Leftover(
                    url: item,
                    size: size,
                    category: owner.category,
                    potentialOwner: Identity(
                        bundleID: owner.category == .orphaned && owner.ownerID.contains(".")
                            ? owner.ownerID : nil,
                        name: owner.cask?.capitalized
                            ?? Self.recordedName(for: owner.ownerID, in: knownNames)
                            ?? Self.readableName(ownerID: owner.ownerID, url: item, qualified: qualified)
                    ),
                    evidence: evidence,
                    capability: capability(for: item, in: domain),
                    lastAccessed: lastAccessed(of: item),
                    removedAt: owner.category == .orphaned ? removedApplications[owner.ownerID.lowercased()] : nil,
                    sizeIsKnown: measured.state == .complete
                )
                leftovers.append(leftover)
            }
        }
        return leftovers
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    /// What every domain's walk matches against, worked out once per scan
    /// rather than once per domain: a subject for each installed and removed
    /// app, the container claimants and the installed lookup, with identifiers
    /// lowercased and bundle paths standardised once.
    private struct Prepared: Sendable {
        let activeSubjects: [LocationInventory.Subject]
        let pastSubjects: [LocationInventory.Subject]
        /// Library helpers can protect a shared container even though they
        /// are deliberately excluded from an app's removal identifiers.
        let containerClaimants: Set<String>
        let installed: InstalledLookup
        let inventoryRoots: Set<String>

        init(active: [Identity], past: [Identity], activeBundleIDs: Set<String>, root: FileSystemRoot) {
            activeSubjects = active.map(LocationInventory.Subject.init)
            pastSubjects = past.map(LocationInventory.Subject.init)
            containerClaimants = Set(active.flatMap {
                [$0.bundleID].compactMap(\.self) + ($0.identitySurface?.bundleIdentifiers ?? [])
            }.map { $0.lowercased() })
            installed = InstalledLookup(
                identifiersLowercased: Set(activeBundleIDs.map { $0.lowercased() }),
                bundlePaths: active.compactMap(\.bundlePath).map {
                    URL(fileURLWithPath: $0).standardizedFileURL.path
                }
            )
            inventoryRoots = Set(LocationInventory.standard.locations.map {
                root.url(for: $0.domain).resolvingSymlinksInPath().path
            })
        }
    }

    private struct OwnerLookup {
        let domain: FileSystemRoot.Domain
        let locationRules: [LocationInventory.Location]
        let pastIdentities: [Identity]
        let pastSubjects: [LocationInventory.Subject]
        let search: OwnershipSearch
    }

    private struct ResolvedOwner {
        let category: Leftover.Category
        let evidence: String
        let ownerID: String
        let cask: String?
    }

    private nonisolated func resolvedOwner(
        for item: URL, name: String, qualified: String,
        containerOwner: String?, declared: String? = nil, lookup: OwnerLookup
    ) -> ResolvedOwner? {
        let embeddedID = lookup.locationRules.contains { $0.rule == .identifierInsideBundle }
            ? LocationInventorySource.declaredIdentifier(at: item) : declared
        let recordedOwner = Self.recordedOwner(name: name, declaredIdentifier: embeddedID, lookup: lookup)
        let ownerID = recordedOwner ?? containerOwner ?? declared
            ?? extractOwnerIdentifier(from: item, in: lookup.domain)

        // Presence beats any stale record. Try the identifier and both
        // names because a folder does not always use the bundle ID.
        let parentID: String? = containerOwner.flatMap { identifier in
            guard let namespace = OwnerNamespace.key(for: identifier) else { return nil }
            let depth = namespace.split(separator: ".").count
            return identifier.split(separator: ".").prefix(depth).joined(separator: ".")
        }
        let verdict = Self.strongestOwnership(
            among: [ownerID, name, qualified] + [parentID].compactMap(\.self),
            search: lookup.search
        )
        if case .present = verdict {
            return nil
        }
        if let uncertain = Self.uncertainOwner(verdict, ownerID: ownerID) {
            return uncertain
        }

        let cask = Self.matchingOrphanedCask(
            ownerID: ownerID, name: qualified, among: homebrewOrphans
        )
        if let cask {
            return ResolvedOwner(
                category: .orphaned,
                evidence: "Homebrew lists \(cask), but its app is not installed.",
                ownerID: ownerID, cask: cask
            )
        }
        if let containerOwner {
            return ResolvedOwner(
                category: .orphaned,
                evidence: "Container metadata names \(containerOwner); its app is not installed.",
                ownerID: ownerID, cask: nil
            )
        }
        guard let category = verdict.category else { return nil }
        if case let .recordedButGone(sentence) = verdict {
            return ResolvedOwner(category: category, evidence: sentence, ownerID: ownerID, cask: nil)
        }
        return ResolvedOwner(
            category: category,
            evidence: "No installed app or ownership record claims this.",
            ownerID: ownerID, cask: nil
        )
    }

    private static func recordedOwner(name: String, declaredIdentifier: String?, lookup: OwnerLookup) -> String? {
        zip(lookup.pastIdentities, lookup.pastSubjects).first { _, subject in
            lookup.locationRules.contains {
                $0.matchTier(name: name, subject: subject,
                             declaredIdentifier: declaredIdentifier) != nil
            }
        }?.0.bundleID
    }

    private static func uncertainOwner(_ verdict: Ownership, ownerID: String) -> ResolvedOwner? {
        guard case let .unknown(sentence) = verdict else { return nil }
        return ResolvedOwner(category: .unclaimed, evidence: sentence, ownerID: ownerID, cask: nil)
    }

    private static func strongestOwnership(
        among names: [String], search: OwnershipSearch
    ) -> Ownership {
        names.map(search.ownership(of:))
            .reduce(.unattributable) { strongest, next in
                switch (strongest, next) {
                case (.present, _): strongest
                case (_, .present): next
                case (.unknown, _): strongest
                case (_, .unknown): next
                case (.recordedButGone, _): strongest
                case (_, .recordedButGone): next
                default: strongest
                }
            }
    }

    /// The folders macOS shares with installers, where a plain name is macOS's.
    static let systemDomains: Set<FileSystemRoot.Domain> = [
        .systemApplicationSupport, .systemCaches, .systemLogs,
        .systemPreferences, .systemContainers, .systemDiagnosticReports,
        .systemServices, .systemQuickLook, .systemSpotlight, .systemAutomator,
        .systemColorPickers, .systemScreenSavers, .systemInternetPlugIns,
        .systemPreferencePanes, .systemExtensionsFolder, .startupItems,
        .systemApplicationScripts, .systemDictionaries
    ]

    /// Whether a plainly named entry in a system folder belongs to macOS.
    /// `/Library` holds Apple's work under ordinary names (`Apple`, `BTServer`),
    /// which the reverse-DNS test cannot see. So in a system folder only an
    /// entry named like a bundle identifier is a candidate, which is how
    /// third-party installers name what they leave.
    static func isSystemOwnedByName(_ name: String, in domain: FileSystemRoot.Domain) -> Bool {
        guard systemDomains.contains(domain) else { return false }

        // Named like a bundle identifier: at least two dot-separated
        // parts, and the first is a domain-ish token.
        let base = name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
        let parts = base.split(separator: ".")
        return parts.count < 3
    }

    /// The first two components of every reverse-DNS name macOS ships
    /// outside `com.apple`, which is handled on its own.
    static func families(of names: Set<String>) -> Set<String> {
        Set(names.compactMap { name in
            let parts = name.split(separator: ".")
            guard parts.count >= 3 else { return nil }
            let family = parts.prefix(2).joined(separator: ".")
            return family == "com.apple" ? nil : family
        })
    }

    static func isInSystemFamily(_ name: String, families: Set<String>) -> Bool {
        let parts = systemComponentStem(name).split(separator: ".")
        guard parts.count >= 3 else { return false }
        return families.contains(parts.prefix(2).joined(separator: "."))
    }

    /// Apple's by identifier, or signed by a team that also signed an installed
    /// application: a vendor still here may still use it.
    static func belongsToInstalledSoftware(
        identifier: String?, team: String?, activeTeams: Set<String>
    ) -> Bool {
        if let identifier, isAppleOwned(identifier) {
            return true
        }
        if let team {
            return activeTeams.contains(team)
        }
        return false
    }

    /// The identifier and signing team a bundle declares, or nil when this is
    /// not a bundle.
    static func bundleSignature(of url: URL) -> (identifier: String?, team: String?)? {
        guard let plist = LocationInventorySource.bundleInfo(at: url).values else { return nil }
        // The team only from a signature that holds up; a broken signature proves
        // nothing about who made the bundle.
        var team: String?
        if case let .valid(signedBy) = CodeSignature.state(of: url, recordedTeam: nil) {
            team = signedBy
        }
        return (plist["CFBundleIdentifier"] as? String, team)
    }

    /// Protected only when a matching component exists in this Mac's
    /// `/System/Library`. A fixed list would age as macOS changes and could hide
    /// third-party residue.
    static func isInstalledSystemComponent(_ name: String, names: Set<String>) -> Bool {
        let stem = systemComponentStem(name)
        return names.contains(stem)
    }

    static func isMacOSRelocationFolder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let prefix = "Previously Relocated Items "
        let suffix = name.hasPrefix(prefix) ? name.dropFirst(prefix.count) : Substring()
        let isNamed = name == "Relocated Items"
            || name == "Previously Relocated Items"
            || (!suffix.isEmpty && suffix.allSatisfy(\.isNumber))
        return isNamed && FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".localized").path
        )
    }

    private static func systemComponentStem(_ name: String) -> String {
        let lower = name.lowercased()
        for suffix in [".plist", ".framework", ".app", ".appex", ".kext", ".bundle"]
            where lower.hasSuffix(suffix) {
            return String(lower.dropLast(suffix.count))
        }
        return lower
    }

    static func systemNames(in root: FileSystemRoot) -> Set<String> {
        let library = root.rootURL.appendingPathComponent("System/Library")
        let directories = [
            "Frameworks", "PrivateFrameworks", "LaunchAgents", "LaunchDaemons",
            "Extensions", "CoreServices", "PreferencePanes", "Screen Savers"
        ]
        let manager = FileManager.default
        var names = Set<String>()
        for directory in directories {
            let url = library.appendingPathComponent(directory)
            guard let entries = try? manager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                let stem = systemComponentStem(entry.lastPathComponent)
                names.insert(stem)
                if stem.hasPrefix("com.apple.") {
                    names.insert(String(stem.dropFirst("com.apple.".count)))
                }
            }
        }
        return names
    }

    /// Matches both `com.apple.x` and the group-container form
    /// `group.com.apple.x`, and the bare `group.com.apple` prefix used by
    /// several system group containers.
    static func isAppleOwned(_ name: String) -> Bool {
        let identifier: String = if name.hasPrefix("systemgroup.") {
            String(name.dropFirst("systemgroup.".count))
        } else if name.hasPrefix("group.") {
            String(name.dropFirst("group.".count))
        } else {
            name
        }
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

    /// What a symbolic link is, decided by its target, not its name:
    /// `/usr/local/bin` is mostly links into app bundles. A link whose target
    /// exists is that target's business; one whose target is gone is a command
    /// on the PATH that cannot run, one of the cleanest leftovers there is.
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
                "This command points into the missing \($0)."
            } ?? "This command points to a missing file at \(target.path).",
            // Asked, not assumed: these are usually in `/usr/local/bin`, which belongs
            // to root.
            capability: RemovalCapability.forDeleting(url.path),
            lastAccessed: nil
        )
    }

    /// The application or framework a path runs through, if any:
    /// `/Applications/Docker.app/Contents/Resources/bin/docker` is Docker's.
    /// Read from `BrimCore`, so the sweep and registrations agree.
    static func ownerOfPath(_ url: URL) -> String? {
        EnclosingBundle.component(of: url)
    }

    // MARK: - Vendor folders

    /// Domains where one folder can hold several products. Settings and saved
    /// state are one file per identifier; support, caches and logs are where a
    /// vendor makes a folder and puts each product inside.
    static let nestable: Set<FileSystemRoot.Domain> = [
        .userApplicationSupport, .systemApplicationSupport,
        .userCaches, .systemCaches,
        .userLogs, .systemLogs,
        .sharedUser, .sharedApplicationSupport
    ]

    static let commandNamedDomains: Set<FileSystemRoot.Domain> = [
        .userCaches, .userApplicationSupport, .userLogs
    ]

    /// Removed applications as the sweep knows them, longest identifier first.
    /// An app Brim removed itself left its whole identity in the plan; any other
    /// keeps every name Brim recorded. Short names say too little to match on.
    static func pastIdentities(
        _ identifiers: Set<String>, names: [String: String], aliases: [String: [String]], identities: [Identity]
    ) -> [Identity] {
        let full = Dictionary(identities.compactMap { identity in
            identity.bundleID.map { ($0.lowercased(), identity) }
        }, uniquingKeysWith: { first, _ in first })
        return identifiers.sorted { $0.count > $1.count }.map { id in
            if let identity = full[id.lowercased()] {
                return identity
            }
            let name = names[id.lowercased()] ?? ""
            let recorded = (aliases[id.lowercased()] ?? []).filter { NameKey.of($0).count >= 4 }
            return Identity(bundleID: id, name: name.count >= 4 ? name : "", recordedNames: recorded)
        }
    }

    /// Where a link is a command, and a missing target means it cannot run.
    static let commandFolders: Set<FileSystemRoot.Domain> = [
        .usrLocalBin, .usrLocalSbin, .userDotLocalBin
    ]

    static let recordOnlyDomains: Set<FileSystemRoot.Domain> = [
        .userHomeDotFolders, .userDiagnosticReports, .systemDiagnosticReports,
        // iCloud keeps its own databases beside each application's folder,
        // and nothing names those.
        .userCloudKitCaches
    ]

    static let commandLineDataDomains: Set<FileSystemRoot.Domain> = [
        .userDotConfig, .userDotCache, .userDotLocalShare,
        .userDotLocalState, .userDotLocalBin
    ]

    nonisolated static func defaultCommandLookup(
        in root: FileSystemRoot
    ) -> @Sendable (String) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init)
            + ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin",
               root.url(for: .userDotLocalBin).path]
        return { name in
            guard IdentitySurface.isPathComponent(name) else {
                return false
            }
            return directories.contains { directory in
                guard directory.hasPrefix("/") else {
                    return false
                }
                return FileManager.default.isExecutableFile(
                    atPath: URL(fileURLWithPath: directory).appendingPathComponent(name).path
                )
            }
        }
    }

    /// The children to judge in place of this folder, when it is one vendor's
    /// and holds several products. Narrow on purpose: an installed app must be
    /// called `<this folder> <something else>`, so `Google` qualifies while
    /// Google Chrome is installed and `Obsidian` never does.
    nonisolated func vendorFolderChildren(
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

    /// What every item in a domain is compared against, prepared once.
    private struct InstalledLookup {
        let identifiersLowercased: Set<String>
        /// Standardised, so a folder can be tested as one an app runs from.
        let bundlePaths: [String]

        /// The identifier or one of its parents, so a helper or extension appending
        /// a component to an installed app's identifier is that app's. Asked of the
        /// name's own dotted prefixes, a few set lookups.
        func containsIdentifierOrParent(of lowerName: String) -> Bool {
            var candidate = Substring(lowerName)
            while !candidate.isEmpty {
                if identifiersLowercased.contains(String(candidate)) {
                    return true
                }
                guard let dot = candidate.lastIndex(of: ".") else { return false }
                candidate = candidate[..<dot]
            }
            return false
        }
    }

    private nonisolated func isItemActive(
        item: URL,
        in domain: FileSystemRoot.Domain,
        vendor: String?,
        containerOwner: String?,
        locationRules: [LocationInventory.Location],
        installed: InstalledLookup,
        activeSubjects: [LocationInventory.Subject],
        activeBundleIDs: Set<String>,
        activeNames: Set<String>,
        activeGroupContainers: Set<String>,
        activeTeamIDs: Set<String>,
        writers: [ProvenanceSource.Owner] = []
    ) -> Bool {
        let name = item.lastPathComponent
        if ProvenanceSource.owner(of: item, among: writers) != nil {
            return true
        }
        // A folder an installed application runs from, such as
        // `Application Support/Microsoft/MAU2.0`.
        let inside = item.standardizedFileURL.path + "/"
        if installed.bundlePaths.contains(where: { $0.hasPrefix(inside) }) {
            return true
        }
        if locationRules.contains(where: { $0.rule == .applicationName || $0.rule == .applicationNameLowercased }),
           activeNames.contains(name.lowercased()) {
            return true
        }
        let lowerName = name.lowercased()
        // A helper, widget, or extension often appends a component to its
        // parent bundle identifier. The installed parent still owns it.
        if installed.containsIdentifierOrParent(of: lowerName) {
            return true
        }
        if let containerOwner {
            let ownerIsActive = activeSubjects.contains { $0.longestIdentifier(prefixing: containerOwner) != nil }
            if ownerIsActive {
                return true
            }
        }
        if isCommandLineItemActive(item, in: domain) {
            return true
        }
        let declaredIdentifier = locationRules.contains { $0.rule == .identifierInsideBundle }
            ? LocationInventorySource.declaredIdentifier(at: item) : nil

        if locationRules.contains(where: { location in
            activeSubjects.contains { subject in
                location.matchTier(name: name, subject: subject,
                                   declaredIdentifier: declaredIdentifier) != nil
            }
        }) {
            return true
        }

        // Inside a vendor folder the app's real name is the two together, which
        // some installers write with a dot.
        if let vendor {
            if activeNames.contains("\(vendor) \(name)".lowercased()) {
                return true
            }
            if activeBundleIDs.contains("\(vendor).\(name)") {
                return true
            }
        }

        switch domain {
        case .userGroupContainers, .userApplicationScripts, .systemApplicationScripts:
            return Self.isActiveGroup(name, groups: activeGroupContainers, teams: activeTeamIDs,
                                      bundleIDs: activeBundleIDs, names: activeNames)

        case .userWebKit, .userContainers:
            if activeBundleIDs.contains(name) {
                return true
            }
            if activeNames.contains(lowerName) {
                return true
            }
            if domain == .userContainers {
                if let base = name.split(separator: ".").last, activeNames.contains(base.lowercased()) {
                    return true
                }
            }
            return false

        default:
            return locationRules.isEmpty
                && (activeBundleIDs.contains(name) || activeNames.contains(lowerName))
        }
    }

    static func isActiveGroup(
        _ name: String, groups: Set<String>, teams: Set<String>, bundleIDs: Set<String>, names: Set<String>
    ) -> Bool {
        if groups.contains(name) {
            return true
        }
        for teamID in teams {
            if name.hasPrefix(teamID + ".") {
                let suffix = String(name.dropFirst(teamID.count + 1))
                if bundleIDs.contains(suffix) || names.contains(suffix.lowercased()) {
                    return true
                }
                // A suffix that is not a product identifier names a developer's shared
                // container (`UBF8T346G9.ms`), which stays while any of their apps is
                // installed. A product's own container, `TEAM.com.example.app`, is offered
                // once that product is gone.
                if suffix.split(separator: ".").count < 3 {
                    return true
                }
            }
        }
        if let dotIndex = name.firstIndex(of: ".") {
            let suffix = String(name[name.index(after: dotIndex)...])
            if bundleIDs.contains(suffix) || names.contains(suffix.lowercased()) {
                return true
            }
        }
        return false
    }

    static let containerNames: Set<String> = ["caches", "cache", "logs", "data", "tmp", "temp"]

    /// The newest change to the item or anything two levels inside it,
    /// reading at most a few hundred entries.
    static func newestWrite(in url: URL) -> Date? {
        let key: Set<URLResourceKey> = [.contentModificationDateKey]
        var newest = (try? url.resourceValues(forKeys: key))?.contentModificationDate
        guard isDirectory(url), let walk = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(key), options: [.skipsPackageDescendants]
        ) else { return newest }
        var read = 0
        for case let child as URL in walk {
            read += 1
            if read > 400 {
                break
            }
            if walk.level > 2 {
                walk.skipDescendants(); continue
            }
            if let date = (try? child.resourceValues(forKeys: key))?.contentModificationDate,
               date > (newest ?? .distantPast) {
                newest = date
            }
        }
        return newest
    }

    /// Whether a folder's own first level holds a file named `com.apple.…`.
    static func holdsApplesOwnFile(_ url: URL) -> Bool {
        guard isDirectory(url),
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        else { return false }
        return names.prefix(200).contains { $0.hasPrefix("com.apple.") }
    }

    private nonisolated func isCommandLineItemActive(
        _ item: URL, in domain: FileSystemRoot.Domain
    ) -> Bool {
        // A command line tool keeps its cache and support folders under its own
        // name (`SwiftLint` for `swiftlint`), which no app inventory claims.
        if Self.commandNamedDomains.contains(domain), commandIsInstalled(item.lastPathComponent.lowercased()) {
            return true
        }
        // `~/.claude` is the `claude` command's, and `~/.cargo-tools` cargo's.
        if domain == .userHomeDotFolders {
            let bare = item.lastPathComponent.dropFirst()
            return bare.split(separator: "-").first.map { commandIsInstalled(String($0)) } ?? false
        }
        guard Self.commandLineDataDomains.contains(domain) else {
            return false
        }
        if commandIsInstalled(item.lastPathComponent) {
            return true
        }
        return domain == .userDotLocalBin && !Self.isDirectory(item)
            && FileManager.default.isExecutableFile(atPath: item.path)
    }

    private nonisolated func scanDirectoryLevel1(_ url: URL, hidden: Bool = false) -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: hidden ? [] : .skipsHiddenFiles
        ) else {
            return []
        }
        return urls
    }

    /// Which orphaned cask this item belongs to, matched on a whole component:
    /// `warp` matches `dev.warp`, not `warpdrive`.
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
            if components.contains(normalised) {
                return true
            }
            // Homebrew hyphenates: boring-notch against boringnotch.
            let squashed = normalised.filter { $0.isLetter || $0.isNumber }
            return components.contains(squashed)
        }
    }

    /// The name recorded for this identifier or the app it is inside, longest
    /// match winning, so `com.microsoft.teams2.agent` is Microsoft Teams too.
    static func recordedName(for ownerID: String, in names: [String: String]) -> String? {
        let owner = ownerID.lowercased()
        guard !owner.isEmpty, !names.isEmpty else { return nil }
        return names.filter { owner == $0.key || owner.hasPrefix($0.key + ".") }
            .max { $0.key.count < $1.key.count }?.value
    }

    /// Something a person can read, instead of a team identifier and a
    /// reverse-DNS name.
    static func readableName(ownerID: String, url: URL, qualified: String? = nil) -> String {
        // Inside a vendor folder the vendor is half the name.
        if let qualified, qualified != url.lastPathComponent {
            return qualified
        }
        let candidate = ownerID.isEmpty
            ? url.deletingPathExtension().lastPathComponent : ownerID
        if let namespace = OwnerNamespace.key(for: url.lastPathComponent) {
            return OwnerNamespace.displayName(for: namespace)
        }
        if let namespace = OwnerNamespace.key(for: candidate) {
            return OwnerNamespace.displayName(for: namespace)
        }
        // An updater's folder is named for the app it updates:
        // `notion-updater` is Notion's.
        for suffix in ["-updater", "_updater"] where candidate.lowercased().hasSuffix(suffix)
            && candidate.count > suffix.count {
            let app = candidate.dropLast(suffix.count)
            return app.prefix(1).uppercased() + app.dropFirst()
        }
        // The last meaningful part of a reverse-DNS name: `com.example.app` is
        // App. A file extension is not a product name.
        let parts = candidate.split(separator: ".")
        guard let last = parts.last, parts.count > 2 else { return candidate }
        return String(last).capitalized
    }

    private nonisolated func extractOwnerIdentifier(from url: URL, in domain: FileSystemRoot.Domain) -> String {
        let name = url.lastPathComponent
        if domain == .userPreferences && name.hasSuffix(".plist") {
            return String(name.dropLast(6))
        }
        // `ChatGPTHelper.binarycookies` is ChatGPTHelper's, not Binarycookies'.
        if (domain == .userHTTPStorages || domain == .userCookies) && name.hasSuffix(".binarycookies") {
            return String(name.dropLast(14))
        }
        if domain == .userSavedApplicationState && name.hasSuffix(".savedState") {
            return String(name.dropLast(11))
        }
        // Both are named `<teamID>.<bundle id>`, so the owner follows the team.
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

    /// Whether Brim can remove this, rather than only see it. A sandbox
    /// container's metadata cannot be unlinked without Full Disk Access, and
    /// `sudo` does not help since TCC judges the responsible app. Everything else
    /// asks the folder's permissions through `RemovalCapability`, so nothing is
    /// offered that the kernel will refuse.
    private nonisolated func capability(for url: URL, in domain: FileSystemRoot.Domain) -> Capability {
        switch domain {
        case .userContainers, .userGroupContainers:
            hasFullDiskAccess ? .ok : .needsFullDiskAccess
        default:
            RemovalCapability.forDeleting(url.path)
        }
    }

    private nonisolated func lastAccessed(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
    }

    /// Every installed application's identity, with both its file name and its
    /// `CFBundleName`, since an app names its support folder after the latter.
    private func gatherActiveAppIdentities() async -> (identities: [Identity], complete: Bool) {
        let inventory = await Task.detached { InstalledBundleInventory.read(in: self.root) }.value
        var identities: [Identity] = []
        var complete = inventory.completeness.isComplete
        let budget = ScanBudget(total: 20)
        // Read four at a time; one after another, this was the slowest part of the
        // scan.
        let root = root
        let bundles = inventory.claimingBundles
        let allClaims = await (try? BoundedTasks.map(bundles, limit: 4) { bundle in
            budget.hasRunOut ? nil : BundleSurfaceReader.protectionClaims(at: bundle, in: root)
        }) ?? []
        for (index, bundle) in bundles.enumerated() {
            guard index < allClaims.count, let claims = allClaims[index], !Task.isCancelled else {
                complete = false; break
            }
            let identity = await resolver.resolve(bundleURL: bundle)
            complete = complete && claims.complete
            // These claims stay in the protective sweep: never passed to the uninstall
            // evidence engine or used to select a deletion.
            identities.append(Identity(bundleID: identity.bundleID, teamID: identity.teamID,
                                       name: identity.name, bundleName: identity.bundleName,
                                       groupContainers: claims.surface.groups,
                                       bundlePath: bundle.path,
                                       identitySurface: claims.surface))
        }
        return (identities, complete)
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
