import BrimCore
import Darwin
import Foundation

// swiftformat:disable wrapMultilineStatementBraces

public actor LeftoversScanner {
    public let root: FileSystemRoot
    private let resolver: IdentityResolver
    /// Launch Services' answer for a bundle identifier. Injected so the
    /// ownership rules can be tested without depending on what happens to be
    /// installed on the machine running the suite.
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
    /// Supplied by the caller because enumerating them is the registration
    /// sweep's job, not this scanner's.
    private let staleRegistrationOwners: [String: String]
    /// Homebrew casks whose application is gone. A package manager's own
    /// record is exactly the kind of evidence that turns an unattributed
    /// folder into a named orphan, and nothing was reading it.
    private let homebrewOrphans: Set<String>
    /// Paths another part of Brim already accounts for: the Developer
    /// catalogue's caches. Homebrew's downloads and SwiftPM's cache were
    /// listed here as "owner unknown" and on Developer as build caches, and
    /// Space added them twice.
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
            // Both identifiers shipped in older builds. Their preference
            // and cache records still belong to this running application.
            for oldID in SafetyChecker.identifiersOlderBuildsUsed {
                gatheredIdentities.append(Identity(bundleID: oldID, name: own.name))
            }
        }
        let activeIdentities = gatheredIdentities
        let receiptBundleIDs = await gatherInstallerReceipts()

        let activeBundleIDs = Set(activeIdentities.flatMap(\.searchBundleIdentifiers))
        // The bundle's own `CFBundleName` as well as what the icon says,
        // because an application's support folder is named after the
        // former. Visual Studio Code calls itself Code in its
        // `Info.plist` and writes a hundred and thirty megabytes to
        // `Application Support/Code`, and the sweep was offering all of
        // it up while the application was installed and running.
        //
        // Read off `Identity` rather than gathered again here. This scanner
        // learned about `CFBundleName` first and kept the knowledge to
        // itself, so the uninstall path went on not knowing and failed to
        // remove the same folder this one correctly refused to offer.
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

        // Driven by the same inventory the uninstall path uses, rather
        // than a second list kept by hand. The two had drifted: removing
        // an application looked in sixty places and sweeping for what
        // software left behind looked in eight, so /Library, every
        // installer receipt and every command line tool were invisible.
        let domainsToScan = LocationInventory.sweepDomains
        let inventoryRoots = Set(LocationInventory.standard.locations.map {
            root.url(for: $0.domain).resolvingSymlinksInPath().path
        })

        // One task per domain. Each walk reads a different directory tree
        // and writes nothing the others can see: the ownership search, the
        // active-application sets and the Homebrew list are all values,
        // fixed before the walk starts, and the scanner's own stored
        // properties are all `let`. So the domains are independent by
        // construction rather than by inspection, which is the only reason
        // this is safe to run in parallel.
        //
        // Sequentially this was the slowest thing in the app: 654ms of
        // directory enumeration and size accounting, with `Application
        // Support` and the caches dominating while the small domains
        // waited their turn. Sorted afterwards, so the answer does not
        // depend on which domain finished first.
        // What installed applications wrote, by macOS's own record. ChatGPT's
        // 1.6 GB `~/.cache/codex-runtimes` was offered as a leftover with no
        // owner while ChatGPT was installed and using it.
        let writers = ProvenanceSource.owners(of: activeIdentities)
        let vendors = SystemVendors(
            installed: activeIdentities, recorded: knownNames, past: pastIdentities,
            packageFolders: InstalledBundleInventory.packageInstallFolders(in: root), root: root
        )
        let batches = try await BoundedTasks.map(domainsToScan) { [self] domain in
            walkDomain(domain, search, activeIdentities, pastIdentities,
                       activeBundleIDs, activeNames,
                       activeGroupContainers, activeTeamIDs, inventoryRoots, writers, knownNames, vendors)
        }
        let found = batches.flatMap(\.self)
        let leftovers = Self.protectUncertainOwnership(found, complete: gathered.complete)

        // Sorted by size descending. Access time is carried on each item and
        // may be used to order them, but never to argue that something is
        // disposable: nothing having read a file lately says nothing about
        // whether its owner is gone.
        return leftovers.sorted { $0.size > $1.size }
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
        _ activeIdentities: [Identity],
        _ pastIdentities: [Identity],
        _ activeBundleIDs: Set<String>,
        _ activeNames: Set<String>,
        _ activeGroupContainers: Set<String>,
        _ activeTeamIDs: Set<String>,
        _ inventoryRoots: Set<String>,
        _ writers: [ProvenanceSource.Owner],
        _ knownNames: [String: String],
        _ vendors: SystemVendors
    ) -> [Leftover] {
        var leftovers: [Leftover] = []
        let locationRules = LocationInventory.standard.locations.filter { $0.domain == domain }
        let ownerLookup = OwnerLookup(
            domain: domain, locationRules: locationRules,
            pastIdentities: pastIdentities,
            pastSubjects: pastIdentities.map(LocationInventory.Subject.init), search: search
        )
        // Matching reads each identity's identifiers once per file, so they
        // are worked out once per domain rather than once per question.
        let activeSubjects = activeIdentities.map(LocationInventory.Subject.init)
        // Library helpers can protect a shared container even though they
        // are deliberately excluded from an app's removal identifiers.
        let containerClaimants = Set(activeIdentities.flatMap {
            [$0.bundleID].compactMap(\.self) + ($0.identitySurface?.bundleIdentifiers ?? [])
        }.map { $0.lowercased() })
        do {
            let dir = root.url(for: domain)
            // A vendor folder puts its children on the queue in place of
            // itself, so the walk is one level deep and only where there
            // is a reason to go deeper.
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
                // The name to reason about: `Chrome` inside `Google` is
                // `Google Chrome`, which is what the application is
                // actually called and the only spelling that matches it.
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
                if Self.isAppleOwned(name) || Self.isInstalledSystemComponent(name, names: systemLibraryNames) {
                    continue
                }

                // A name in a family macOS itself ships. CUPS is part of
                // macOS and names its files `org.cups.*`, so the printer list
                // in /Library/Preferences was offered as an unclaimed
                // leftover while every printer on the Mac depended on it.
                if Self.isInSystemFamily(name, families: systemFamilies) {
                    continue
                }

                // A bundle says whose it is, in its own Info.plist and in its
                // signature, and that outranks anything its file name
                // suggests. `ParrotAudioPlugin.driver` is Apple's by its
                // identifier, and `MSTeamsAudioDevice.driver` is signed by the
                // team that signed Microsoft Teams, which is installed.
                let signed = Self.bundleSignature(of: item)
                if let signed, Self.belongsToInstalledSoftware(
                    identifier: signed.identifier, team: signed.team, activeTeams: activeTeamIDs
                ) {
                    continue
                }

                // Folders in the system domain that macOS itself put
                // there. They are not named after a bundle, so the
                // reverse-DNS test above never sees them, and offering to
                // remove /Library/Application Support/Apple would be a
                // serious thing to get wrong.
                //
                // Unless a third party is known by that name. `Microsoft` in
                // `/Library/Logs` held Teams' logs and AutoUpdate's after both
                // had gone, and `Office365` sat in `Application Support/Microsoft`,
                // and the sweep never looked inside either because neither
                // name has dots in it. A developer's folder is judged by what
                // it holds; the folder itself is never offered.
                //
                // A bundle is judged by the identifier it declares, never by
                // its file name. `Flash Player.prefPane` has one dot, so
                // every third-party plug-in in `/Library` was read as macOS's.
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

                // macOS places files it could not migrate during an update
                // in these marked folders under /Users/Shared. They are the
                // person's relocated files, not application residue.
                if domain == .sharedUser, Self.isMacOSRelocationFolder(item) {
                    continue
                }

                // A link is judged by what it points at, never by its
                // name, and that answer arrives before any of the rest.
                switch Self.symlink(item) {
                case .some(.resolved):
                    continue
                case let .some(.dangling(target)):
                    leftovers.append(Self.brokenLink(item, pointingAt: target))
                    continue
                case nil:
                    break
                }

                // A developer's folder in the person's Library is judged by
                // what it holds, as it is in /Library. `Microsoft` in
                // Application Support was only ever looked at whole, because
                // the one Microsoft app installed, Visual Studio Code, has a
                // name that does not begin with the developer's.
                if vendor == nil, signed?.identifier == nil, Self.nestable.contains(domain),
                   !Self.systemDomains.contains(domain), vendors.claim(name) == .developer, Self.isDirectory(item) {
                    queue.append(contentsOf: scanDirectoryLevel1(item).map { ($0, name) })
                    continue
                }

                let containerOwner = containerOwnership?.identifier

                let belongsToInstalledApp = isItemActive(
                    item: item, in: domain, vendor: vendor,
                    containerOwner: containerOwner,
                    locationRules: locationRules, activeIdentities: activeIdentities,
                    activeSubjects: activeSubjects,
                    activeBundleIDs: activeBundleIDs, activeNames: activeNames,
                    activeGroupContainers: activeGroupContainers, activeTeamIDs: activeTeamIDs,
                    writers: writers
                )
                if belongsToInstalledApp {
                    continue
                }

                // A folder called `Caches` or `Logs` inside a place apps
                // keep things is somebody's container, not somebody. Notion
                // keeps its updater in `Application Support/Caches`, and
                // the row read "Caches".
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

                // Inside a developer's folder in a system location, anything no
                // gone product is named in may be shared, an updater or a
                // licence, and stays while any of that developer's software is
                // installed. Google's updater serves Chrome from there.
                // A folder holding a file macOS names for itself is macOS's,
                // whatever the folder is called: `CallHistoryDB` holds
                // `com.apple.callhistory.databaseInfo.plist`, and was offered
                // while macOS wrote to it the same morning.
                if owner.category == .unclaimed, Self.holdsApplesOwnFile(item) {
                    continue
                }
                // Where a name is all there is to go on, only a record of an
                // app that was here and has gone names an owner. A dot folder
                // nobody claims is a tool's settings as often as not, and a
                // crash report nobody claims says nothing about whose it is.
                if Self.recordOnlyDomains.contains(domain), owner.category != .orphaned {
                    continue
                }
                // Nothing names it, and something wrote to it this week.
                // Whatever that is, it is alive, so this is not what a
                // removed app left. `Knowledge`, `Animoji` and
                // `SiriEntityCache` are macOS's and were written the day
                // they were offered here. Recent writing only ever keeps
                // a folder out; it never argues that one is a leftover.
                if owner.category == .unclaimed, let window = inUseWithin,
                   Self.newestWrite(in: item).map({ Date().timeIntervalSince($0) < window }) == true {
                    continue
                }

                // macOS protects it for itself, so it is nobody's leftover
                // and nobody can remove it.
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
    static let systemDomains: Set<FileSystemRoot.Domain> = [
        .systemApplicationSupport, .systemCaches, .systemLogs,
        .systemPreferences, .systemContainers, .systemDiagnosticReports,
        .systemServices, .systemQuickLook, .systemSpotlight, .systemAutomator,
        .systemColorPickers, .systemScreenSavers, .systemInternetPlugIns,
        .systemPreferencePanes, .systemExtensionsFolder, .startupItems,
        .systemApplicationScripts, .systemDictionaries
    ]

    static func isSystemOwnedByName(_ name: String, in domain: FileSystemRoot.Domain) -> Bool {
        guard systemDomains.contains(domain) else { return false }

        // Named like a bundle identifier: at least two dot-separated
        // parts, and the first is a domain-ish token.
        let base = name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
        let parts = base.split(separator: ".")
        return parts.count < 3
    }

    /// A name is protected only when a corresponding component exists under
    /// this machine's /System/Library. A generic vendor or framework list
    /// would age as macOS changes and could hide third-party residue.
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

    /// Apple's by identifier, or signed by a team that also signed an
    /// installed application. A vendor that is still here may still use it,
    /// and "might be in use" is not a leftover.
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

    /// The identifier and signing team a bundle declares, or nil when this
    /// is not a bundle. Read only for bundles, so a folder of caches costs
    /// one failed file lookup.
    static func bundleSignature(of url: URL) -> (identifier: String?, team: String?)? {
        guard let plist = LocationInventorySource.bundleInfo(at: url).values else { return nil }
        // The team only from a signature that holds up, read the one way
        // this module reads signatures. A broken signature proves nothing
        // about who made the bundle.
        var team: String?
        if case let .valid(signedBy) = CodeSignature.state(of: url, recordedTeam: nil) {
            team = signedBy
        }
        return (plist["CFBundleIdentifier"] as? String, team)
    }

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

    /// Sandbox containers can have UUID directory names. The container
    /// manager's owner identifier is a disk record, unlike a guess from
    /// creation time or neighbouring UUIDs.
    static func containerOwnerIdentifier(
        at url: URL, in domain: FileSystemRoot.Domain
    ) -> String? {
        guard domain == .userContainers || domain == .systemContainers else { return nil }
        return ContainerOwnershipReader.read(at: url).identifier
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
                "This command points into the missing \($0)."
            } ?? "This command points to a missing file at \(target.path).",
            // Asked, not assumed. These sit in `/usr/local/bin` more often
            // than anywhere else, and that directory belongs to root.
            capability: RemovalCapability.forDeleting(url.path),
            lastAccessed: nil
        )
    }

    /// The application or framework a path runs through, if any.
    ///
    /// `/Applications/Docker.app/Contents/Resources/bin/docker` is
    /// Docker's whatever the command at the end is called, and saying
    /// Docker is the difference between a row somebody understands and a
    /// row saying `kubectl.docker`.
    /// Reads through to `BrimCore`, so the sweep and the registrations list
    /// cannot drift on who owns a path.
    static func ownerOfPath(_ url: URL) -> String? {
        EnclosingBundle.component(of: url)
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
        .sharedUser, .sharedApplicationSupport
    ]

    static let commandNamedDomains: Set<FileSystemRoot.Domain> = [
        .userCaches, .userApplicationSupport, .userLogs
    ]

    /// Removed applications as the sweep knows them, longest identifier
    /// first. An app Brim removed itself left its whole identity in the
    /// plan, helpers included, which says more than any name history kept.
    /// Any other keeps every name Brim recorded, so a folder named after the
    /// app, not its identifier, is recognised as its too. Short names say
    /// too little to match on.
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

    private nonisolated func isItemActive(
        item: URL,
        in domain: FileSystemRoot.Domain,
        vendor: String?,
        containerOwner: String?,
        locationRules: [LocationInventory.Location],
        activeIdentities: [Identity],
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
        // A folder an installed application runs from. Microsoft AutoUpdate
        // lives in `Application Support/Microsoft/MAU2.0`.
        let inside = item.standardizedFileURL.path + "/"
        if activeIdentities.contains(where: { identity in
            identity.bundlePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path.hasPrefix(inside) } ?? false
        }) {
            return true
        }
        if locationRules.contains(where: { $0.rule == .applicationName || $0.rule == .applicationNameLowercased }),
           activeNames.contains(name.lowercased()) {
            return true
        }
        let lowerName = name.lowercased()
        // A helper, widget, or extension often appends a component to its
        // parent bundle identifier. The installed parent still owns it.
        if activeBundleIDs.contains(where: { identifier in
            lowerName == identifier.lowercased()
                || lowerName.hasPrefix(identifier.lowercased() + ".")
        }) {
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

        // Inside a vendor folder the application's real name is the two
        // put together, and some installers write it with a dot instead.
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

    private static func isActiveGroup(
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
        // A command-line tool keeps its cache and support folder under its
        // own name, `SwiftLint` for `swiftlint`, with nothing an app
        // inventory would ever claim.
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
            if components.contains(normalised) {
                return true
            }
            // Homebrew hyphenates: boring-notch against boringnotch.
            let squashed = normalised.filter { $0.isLetter || $0.isNumber }
            return components.contains(squashed)
        }
    }

    /// Something a person can read, instead of a team identifier and a
    /// reverse-DNS name.
    /// The name Brim recorded for this identifier or the application it is
    /// inside, the longest match winning, so `com.microsoft.teams2.agent`
    /// is Microsoft Teams too.
    static func recordedName(for ownerID: String, in names: [String: String]) -> String? {
        let owner = ownerID.lowercased()
        guard !owner.isEmpty, !names.isEmpty else { return nil }
        return names.filter { owner == $0.key || owner.hasPrefix($0.key + ".") }
            .max { $0.key.count < $1.key.count }?.value
    }

    static func readableName(ownerID: String, url: URL, qualified: String? = nil) -> String {
        // Inside a vendor folder the vendor is half the name, and
        // dropping it leaves a row saying "Chrome" beside one saying
        // "Updater" with nothing to connect them.
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
        // The last meaningful component: dev.warp becomes Warp,
        // com.example.app becomes App.
        let parts = candidate.split(separator: ".")
        guard let last = parts.last, parts.count > 1 else { return candidate }
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
    ///
    /// Everything else asks the permissions, which is the question the old
    /// default answer of `.ok` was assuming away. Fourteen broken commands
    /// in `/usr/local/bin` were offered, ticked, planned, authorized and
    /// then refused by the kernel, because that directory is `root:wheel`
    /// and `drwxr-xr-x` and unlinking a name edits the directory holding
    /// it. The person got a wall of text after the fact saying each one
    /// needed an administrator, which `RemovalCapability` could have said
    /// before anything was promised. Same incident as the two Keystone jobs
    /// in `/Library/LaunchAgents`, in a different module.
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

    /// Every installed application's identity.
    ///
    /// Each one carries both names it answers to. `Identity.name` is the
    /// bundle's file name, so `Visual Studio Code.app` becomes "Visual
    /// Studio Code"; `Identity.bundleName` is its `CFBundleName`, which is
    /// what it names its own support folder after, and Visual Studio
    /// Code's is "Code". Reading only the file name left `Application
    /// Support/Code` looking unclaimed while the application sat in
    /// `/Applications`.
    private func gatherActiveAppIdentities() async -> (identities: [Identity], complete: Bool) {
        let inventory = await Task.detached { InstalledBundleInventory.read(in: self.root) }.value
        var identities: [Identity] = []
        var complete = inventory.completeness.isComplete
        let budget = ScanBudget(total: 20)
        for bundle in inventory.bundles {
            if budget.hasRunOut || Task.isCancelled {
                complete = false; break
            }
            let identity = await resolver.resolve(bundleURL: bundle)
            let claims = await Task.detached {
                BundleSurfaceReader.protectionClaims(at: bundle, in: self.root)
            }.value
            complete = complete && claims.complete
            // These claims are local to the protective sweep, never passed
            // to the uninstall evidence engine or used to select a deletion.
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
