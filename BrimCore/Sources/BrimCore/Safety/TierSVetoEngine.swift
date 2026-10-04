// swiftformat:disable wrapMultilineStatementBraces
import Foundation

public struct TierSVetoEngine: Sendable {
    private let lookup: @Sendable (String) throws -> [URL]
    private let root: FileSystemRoot
    private let readClaims: @Sendable (URL, FileSystemRoot) -> (surface: IdentitySurface, complete: Bool)
    private let readGroups: (@Sendable (URL, FileSystemRoot) -> (groups: Set<String>, complete: Bool))?

    public init(root: FileSystemRoot, lookup: @escaping @Sendable (String) throws -> [URL] = { _ in [] }) {
        self.lookup = lookup
        self.root = root
        readClaims = { BundleSurfaceReader.protectionClaims(at: $0, in: $1) }
        readGroups = nil
    }

    init(root: FileSystemRoot,
         readGroups: @escaping @Sendable (URL, FileSystemRoot) -> (groups: Set<String>, complete: Bool)) {
        lookup = { _ in [] }
        self.root = root
        readClaims = { BundleSurfaceReader.protectionClaims(at: $0, in: $1) }
        self.readGroups = readGroups
    }

    init(root: FileSystemRoot, lookup: @escaping @Sendable (String) throws -> [URL] = { _ in [] },
         readClaims: @escaping @Sendable (URL, FileSystemRoot) -> (surface: IdentitySurface, complete: Bool)) {
        self.lookup = lookup
        self.root = root
        self.readClaims = readClaims
        readGroups = nil
    }

    public func applyVeto(to footprint: EvaluatedFootprint) async -> EvaluatedFootprint {
        var vettedItems = [EvaluatedItem]()
        let resolver = IdentityResolver(root: root)
        let hasGroupTarget = footprint.items.contains {
            Self.isGroupPath($0.footprintItem.evidence.url)
        }
        let inventory = await otherApplications(besides: footprint.identity, includeGroups: hasGroupTarget)
        let applications = inventory.identities
        let groupClaims = hasGroupTarget ? Self.mergingGroupClaims(
            inventory.groupClaims, applications: applications, complete: inventory.completeness.isComplete
        ) : (owners: [String: String](), complete: true)
        var completeness = footprint.completeness.merging(inventory.completeness)
        let others = Dictionary(applications.flatMap { other in
            Self.protectionIdentifiers(of: other).map { ($0, other.name) }
        }, uniquingKeysWith: { first, _ in first })
        let survivingCopies = Self.survivingCopies(of: footprint.identity, among: applications)

        let context = VetoContext(identity: footprint.identity, applications: applications,
                                  survivingCopies: survivingCopies, groupClaims: groupClaims,
                                  others: others, resolver: resolver)
        for item in footprint.items {
            let result = await vet(item, context: context)
            vettedItems.append(result.item)
            completeness = completeness.merging(result.completeness)
        }

        if Task.isCancelled {
            completeness = completeness.merging(ScanCompleteness(timedOut: [root.rootURL.path]))
        }
        // A partial claimant search cannot support automatic selection either.
        if !completeness.isComplete {
            vettedItems = vettedItems.map(Self.leftUnticked)
        }
        return EvaluatedFootprint(
            identity: footprint.identity, items: vettedItems, completeness: completeness,
            survivingCopies: survivingCopies,
            protectedComponentIdentifiers: footprint.identity.searchBundleIdentifiers.filter { identifier in
                applications.contains { Self.protectionIdentifiers(of: $0).contains(identifier.lowercased()) }
            }
        )
    }

    private struct VetoContext {
        let identity: Identity
        let applications: [Identity]
        let survivingCopies: [Identity]
        let groupClaims: (owners: [String: String], complete: Bool)
        let others: [String: String]
        let resolver: IdentityResolver
    }

    private func vet(
        _ item: EvaluatedItem, context: VetoContext
    ) async -> (item: EvaluatedItem, completeness: ScanCompleteness) {
        var completeness = ScanCompleteness.complete
        var uncertainContainer = false
        // Unticked rows can be promoted by the planner. Veto them now too.
        if case .excluded = item.selection {
            return (item, completeness)
        }
        let targetURL = item.footprintItem.evidence.url
        if Self.isContainer(targetURL) {
            let ownership = ContainerOwnershipReader.read(at: targetURL)
            completeness = completeness.merging(ownership.completeness)
            if let owner = Self.containerOwner(ownership.identifiers, among: context.applications) {
                return (Self.excluded(item, reason:
                    "Container metadata is claimed by \(owner.name), which is still installed."), completeness)
            }
            uncertainContainer = ownership.uncertainty != nil
        }
        if let copy = context.survivingCopies.first,
           !Self.isInsideSelectedBundle(targetURL, identity: context.identity) {
            let location = copy.bundlePath ?? "another installation"
            return (Self.excluded(item, reason: "Shared with \(copy.name) at \(location)."), completeness)
        }
        if let reason = Self.groupVetoReason(for: targetURL, claims: context.groupClaims) {
            return (Self.excluded(item, reason: reason), completeness)
        }
        if let owner = Self.namedFor(targetURL, among: context.others, besides: context.identity) {
            return (Self.excluded(item, reason: "Named for \(owner), which is still installed."), completeness)
        }
        // The installer's own record already says whose this is:
        // a driver installed in the same run carries its own
        // identifier, and that is not a second owner.
        if item.footprintItem.evidence.mechanism != "InstallerPayloadSource",
           let sharedWith = await checkSharedClaims(
               for: targetURL, identity: context.identity, resolver: context.resolver
           ) {
            return (Self.excluded(item, reason: "Shared file claimed by \(sharedWith.name)"), completeness)
        }
        return (uncertainContainer ? Self.leftUnticked(item) : item, completeness)
    }

    private static func containerOwner(_ identifiers: Set<String>, among applications: [Identity]) -> Identity? {
        identifiers.compactMap { identifier in
            applications.first { other in
                Self.protectionIdentifiers(of: other).contains {
                    identifier.lowercased() == $0 || identifier.lowercased().hasPrefix($0 + ".")
                }
            }
        }.first
    }

    private static func excluded(_ item: EvaluatedItem, reason: String) -> EvaluatedItem {
        EvaluatedItem(footprintItem: item.footprintItem, selection: .excluded(reason: reason),
                      costOfError: item.costOfError)
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
    @concurrent
    private func otherApplications(
        besides identity: Identity, includeGroups: Bool
    ) async -> OtherClaimants {
        guard !Task.isCancelled else {
            return OtherClaimants(identities: [], completeness: ScanCompleteness(timedOut: [root.rootURL.path]),
                                  groupClaims: ([:], false))
        }
        let subject = identity.bundlePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        var found: [Identity] = []
        var owners: [String: String] = [:]
        var groupsComplete = true
        let inventory = InstalledBundleInventory.read(
            in: root, including: identity.searchBundleIdentifiers,
            knownLocations: identity.bundlePath.map { [URL(fileURLWithPath: $0)] } ?? [],
            lookup: lookup
        )
        var completeness = inventory.completeness
        let budget = ScanBudget(total: 10)
        for bundle in inventory.bundles {
            // Embedded components of the subject are not other owners.
            let path = bundle.resolvingSymlinksInPath().path
            if let subject, path == subject || path.hasPrefix(subject + "/") {
                continue
            }
            guard !budget.hasRunOut else {
                completeness = completeness.merging(ScanCompleteness(timedOut: [bundle.path]))
                break
            }
            let claims = readClaims(bundle, root)
            if !claims.complete {
                completeness = completeness.merging(ScanCompleteness(unreadable: [bundle.path]))
            }
            if includeGroups {
                // Keep raw claims even when the host has no usable identifier.
                // The injected reader still controls group coverage in its fixtures.
                let groups = readGroups.map { $0(bundle, root) }
                    ?? (groups: Set(claims.surface.groups), complete: claims.complete)
                groupsComplete = groupsComplete && groups.complete
                for group in groups.groups.sorted() {
                    owners[group] = bundle.deletingPathExtension().lastPathComponent
                }
            }
            guard let identifier = claims.surface.components.first?.bundleIdentifier else {
                completeness = completeness.merging(ScanCompleteness(unreadable: [bundle.path]))
                continue
            }
            found.append(Self.claimantIdentity(identifier: identifier, path: path,
                                               claims: claims.surface, subject: identity))
        }
        if Task.isCancelled {
            completeness = completeness.merging(ScanCompleteness(timedOut: [root.rootURL.path]))
        }
        return OtherClaimants(identities: found, completeness: completeness,
                              groupClaims: (owners: owners, complete: groupsComplete))
    }

    private static func claimantIdentity(
        identifier: String, path: String, claims: IdentitySurface, subject: Identity
    ) -> Identity {
        let components = claims.components.filter {
            !isInsideSelectedBundle(URL(fileURLWithPath: $0.path), identity: subject)
        }
        let surface = IdentitySurface(bundlePath: claims.bundlePath, components: components,
                                      helperRequirements: claims.helperRequirements,
                                      homeFolders: claims.homeFolders ?? [])
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return Identity(bundleID: identifier, name: name,
                        bundlePath: path, identitySurface: surface)
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

extension TierSVetoEngine {
    /// Reuse the component claims already read from known installed copies,
    /// including registered copies outside the standard application folders.
    static func mergingGroupClaims(
        _ claims: (owners: [String: String], complete: Bool), applications: [Identity], complete: Bool
    ) -> (owners: [String: String], complete: Bool) {
        var owners = claims.owners
        for application in applications {
            for group in application.searchGroupContainers {
                owners[group] = application.name
            }
        }
        return (owners, claims.complete && complete)
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
}

private struct OtherClaimants: Sendable {
    let identities: [Identity]
    let completeness: ScanCompleteness
    let groupClaims: (owners: [String: String], complete: Bool)
}
