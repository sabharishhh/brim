// swiftformat:disable wrapMultilineStatementBraces
import Foundation

public struct TierSVetoEngine: Sendable {
    private let root: FileSystemRoot
    private let readGroups: @Sendable (URL, FileSystemRoot) -> (groups: Set<String>, complete: Bool)

    public init(root: FileSystemRoot) {
        self.root = root
        readGroups = { BundleSurfaceReader.groupClaims(at: $0, in: $1) }
    }

    init(root: FileSystemRoot,
         readGroups: @escaping @Sendable (URL, FileSystemRoot) -> (groups: Set<String>, complete: Bool)) {
        self.root = root
        self.readGroups = readGroups
    }

    public func applyVeto(to footprint: EvaluatedFootprint) async -> EvaluatedFootprint {
        var vettedItems = [EvaluatedItem]()
        let resolver = IdentityResolver(root: root)
        let hasGroupTarget = footprint.items.contains {
            Self.isGroupPath($0.footprintItem.evidence.url)
        }
        let groupClaims = hasGroupTarget
            ? await otherGroupClaims(besides: footprint.identity) : (owners: [String: String](), complete: true)

        let inventory = await otherApplications(besides: footprint.identity)
        let applications = inventory.identities
        var completeness = footprint.completeness.merging(inventory.completeness)
        let others = Dictionary(applications.flatMap { other in
            Self.protectionIdentifiers(of: other).map { ($0, other.name) }
        }, uniquingKeysWith: { first, _ in first })
        let survivingCopies = Self.survivingCopies(of: footprint.identity, among: applications)

        for item in footprint.items {
            var uncertainContainer = false
            // Unticked rows can be promoted by the planner. Veto them now too.
            if case .excluded = item.selection {
                vettedItems.append(item)
                continue
            }
            do {
                let targetURL = item.footprintItem.evidence.url
                if Self.isContainer(targetURL) {
                    let ownership = ContainerOwnershipReader.read(at: targetURL)
                    completeness = completeness.merging(ownership.completeness)
                    if let owner = ownership.identifiers.compactMap({ identifier in
                        applications.first { other in
                            Self.protectionIdentifiers(of: other).contains {
                                identifier.lowercased() == $0 || identifier.lowercased().hasPrefix($0 + ".")
                            }
                        }
                    }).first {
                        vettedItems.append(EvaluatedItem(
                            footprintItem: item.footprintItem,
                            selection: .excluded(
                                reason: "Container metadata is claimed by \(owner.name), which is still installed."
                            ),
                            costOfError: item.costOfError
                        ))
                        continue
                    }
                    uncertainContainer = ownership.uncertainty != nil
                }
                if let copy = survivingCopies.first,
                   !Self.isInsideSelectedBundle(targetURL, identity: footprint.identity) {
                    let location = copy.bundlePath ?? "another installation"
                    vettedItems.append(EvaluatedItem(
                        footprintItem: item.footprintItem,
                        selection: .excluded(reason: "Shared with \(copy.name) at \(location)."),
                        costOfError: item.costOfError
                    ))
                    continue
                }
                if let reason = Self.groupVetoReason(for: targetURL, claims: groupClaims) {
                    vettedItems.append(EvaluatedItem(
                        footprintItem: item.footprintItem,
                        selection: .excluded(reason: reason),
                        costOfError: item.costOfError
                    ))
                    continue
                }

                if let owner = Self.namedFor(targetURL, among: others, besides: footprint.identity) {
                    vettedItems.append(EvaluatedItem(
                        footprintItem: item.footprintItem,
                        selection: .excluded(reason: "Named for \(owner), which is still installed."),
                        costOfError: item.costOfError
                    ))
                    continue
                }

                // The installer's own record already says whose this is:
                // a driver installed in the same run carries its own
                // identifier, and that is not a second owner.
                if item.footprintItem.evidence.mechanism != "InstallerPayloadSource",
                   let sharedWith = await checkSharedClaims(
                       for: targetURL, identity: footprint.identity, resolver: resolver
                   ) {
                    vettedItems.append(EvaluatedItem(
                        footprintItem: item.footprintItem,
                        selection: .excluded(reason: "Shared file claimed by \(sharedWith.name)"),
                        costOfError: item.costOfError
                    ))
                    continue
                }
            }
            vettedItems.append(uncertainContainer ? Self.leftUnticked(item) : item)
        }

        // A partial claimant search cannot support automatic selection either.
        if !completeness.isComplete {
            vettedItems = vettedItems.map(Self.leftUnticked)
        }
        return EvaluatedFootprint(
            identity: footprint.identity, items: vettedItems, completeness: completeness,
            survivingCopies: survivingCopies
        )
    }

    private static func leftUnticked(_ item: EvaluatedItem) -> EvaluatedItem {
        guard item.selection == .selected else { return item }
        return EvaluatedItem(footprintItem: item.footprintItem, selection: .unselected,
                             costOfError: item.costOfError)
    }

    /// The installed application an identifier-named item belongs to, when
    /// that application's identifier is more specific than this one's.
    ///
    /// Prefix rules take `com.google.Chrome.canary.plist` for Chrome,
    /// because it begins with Chrome's identifier and a dot. It is Chrome
    /// Canary's, and Canary is still installed.
    static func namedFor(_ url: URL, among others: [String: String], besides identity: Identity) -> String? {
        var name = url.lastPathComponent.lowercased()
        if name.hasPrefix(".") {
            name.removeFirst()
        }
        for suffix in [".plist", ".binarycookies", ".savedstate"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        let own = identity.searchBundleIdentifiers.map { $0.lowercased() }
            .filter { name == $0 || name.hasPrefix($0 + ".") }
            .map(\.count).max() ?? 0
        guard own > 0 else { return nil }
        return others.first { identifier, _ in
            identifier.count > own && (name == identifier || name.hasPrefix(identifier + "."))
        }?.value
    }

    /// Other installations, retaining paths even when identifiers agree.
    private func otherApplications(
        besides identity: Identity
    ) async -> (identities: [Identity], completeness: ScanCompleteness) {
        let root = root
        return await Task.detached {
            let subject = identity.bundlePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            var found: [Identity] = []
            let inventory = InstalledBundleInventory.read(in: root)
            var completeness = inventory.completeness
            let budget = ScanBudget(total: 10)
            for bundle in inventory.bundles {
                // Its own parts are not somebody else.
                let path = bundle.resolvingSymlinksInPath().path
                if let subject, path == subject || path.hasPrefix(subject + "/") {
                    continue
                }
                guard !budget.hasRunOut else {
                    completeness = completeness.merging(ScanCompleteness(timedOut: [bundle.path]))
                    break
                }
                let claims = BundleSurfaceReader.protectionClaims(at: bundle, in: root)
                if !claims.complete {
                    completeness = completeness.merging(ScanCompleteness(unreadable: [bundle.path]))
                }
                guard let identifier = claims.surface.components.first?.bundleIdentifier else {
                    completeness = completeness.merging(ScanCompleteness(unreadable: [bundle.path]))
                    continue
                }
                let components = claims.surface.components.filter {
                    !Self.isInsideSelectedBundle(URL(fileURLWithPath: $0.path), identity: identity)
                }
                let surface = IdentitySurface(bundlePath: claims.surface.bundlePath, components: components,
                                              helperRequirements: claims.surface.helperRequirements,
                                              homeFolders: claims.surface.homeFolders ?? [])
                found.append(Identity(bundleID: identifier, name: bundle.deletingPathExtension().lastPathComponent,
                                      bundlePath: path, identitySurface: surface))
            }
            return (found, completeness)
        }.value
    }

    private static func survivingCopies(of identity: Identity, among applications: [Identity]) -> [Identity] {
        guard let identifier = identity.bundleID?.lowercased() else { return [] }
        return applications.flatMap { application -> [Identity] in
            (application.identitySurface?.components ?? []).compactMap { component -> Identity? in
                let identifiers = [component.bundleIdentifier, component.signingIdentifier].compactMap(\.self)
                guard identifiers.contains(where: { $0.lowercased() == identifier }) else { return nil }
                return Identity(bundleID: identity.bundleID, name: component.name, bundlePath: component.path)
            }
        }
    }

    private static func isInsideSelectedBundle(_ url: URL, identity: Identity) -> Bool {
        guard let subject = identity.bundlePath else { return false }
        let selected = URL(fileURLWithPath: subject).resolvingSymlinksInPath().path
        // Compare the entry itself, not the target of a command symlink.
        let path = url.standardizedFileURL.path
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
        return path == selected || path.hasPrefix(selected + "/")
            || parent == selected || parent.hasPrefix(selected + "/")
    }

    private static func groupVetoReason(
        for url: URL, claims: (owners: [String: String], complete: Bool)
    ) -> String? {
        guard isGroupPath(url) else { return nil }
        if let owner = claims.owners[url.lastPathComponent] {
            return "Shared with \(owner)."
        }
        return claims.complete ? nil : "Shared ownership could not be checked."
    }

    private static func isGroupPath(_ url: URL) -> Bool {
        url.path.contains("/Group Containers/") || url.path.contains("/Application Scripts/")
    }

    private static func isContainer(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "Containers"
    }

    private static func protectionIdentifiers(of identity: Identity) -> Set<String> {
        Set(([identity.bundleID].compactMap(\.self) + (identity.identitySurface?.bundleIdentifiers ?? []))
            .map { $0.lowercased() })
    }

    private func otherGroupClaims(besides identity: Identity) async -> (owners: [String: String], complete: Bool) {
        let root = root
        let readGroups = readGroups
        return await Task.detached {
            let inventory = InstalledBundleInventory.read(in: root)
            var owners: [String: String] = [:]
            var complete = inventory.completeness.isComplete
            let subject = identity.bundlePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            let budget = ScanBudget(total: 10)
            for bundle in inventory.bundles {
                // Its own parts are not somebody else. ChatGPT carries
                // CodexCLI.app inside it, claiming the same app group, and the
                // group was kept from ChatGPT's removal as "shared with other
                // installed software" when the other software was ChatGPT.
                let path = bundle.resolvingSymlinksInPath().path
                if let subject, path == subject || path.hasPrefix(subject + "/") {
                    continue
                }
                if budget.hasRunOut {
                    complete = false; break
                }
                let claims = readGroups(bundle, root)
                complete = complete && claims.complete
                for group in claims.groups.sorted() {
                    owners[group] = bundle.deletingPathExtension().lastPathComponent
                }
            }
            return (owners, complete)
        }.value
    }

    private func checkSharedClaims(for url: URL, identity: Identity, resolver: IdentityResolver) async -> Identity? {
        // Cross-identity resolution
        // If the path resolves to an identity that is NOT the footprint's identity, it is shared/owned by someone else
        let resolved = await resolver.resolve(bundleURL: url)
        guard let resolvedID = resolved.bundleID, let footprintID = identity.bundleID,
              resolvedID != footprintID else { return nil }
        // A bundle named inside one of this application's own identifiers
        // is a part of it: ChatGPT's sign-in plug-in is
        // `com.openai.sky.CUAService.AuthorizationPlugin`, inside its Computer
        // Use component. Vetoed as somebody else's, the review said it was
        // "claimed by CodexComputerUseAuthorizationPlugin", which is itself.
        let lowered = resolvedID.lowercased()
        let own = identity.searchBundleIdentifiers.map { $0.lowercased() }
        if own.contains(where: { lowered == $0 || lowered.hasPrefix($0 + ".") }) {
            return nil
        }
        return resolved
    }
}
