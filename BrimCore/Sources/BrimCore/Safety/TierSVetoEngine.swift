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

        let applications = await otherApplications(besides: footprint.identity)
        let others = Dictionary(applications.compactMap { other -> (String, String)? in
            other.bundleID.map { ($0.lowercased(), other.name) }
        }, uniquingKeysWith: { first, _ in first })
        let survivingCopies = applications.filter {
            guard let own = footprint.identity.bundleID, let other = $0.bundleID else { return false }
            return own.lowercased() == other.lowercased()
        }

        for item in footprint.items {
            // Unticked rows can be promoted by the planner. Veto them now too.
            if case .excluded = item.selection {
                vettedItems.append(item)
                continue
            }
            do {
                let targetURL = item.footprintItem.evidence.url
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
                if Self.isGroupPath(targetURL) {
                    if let other = groupClaims.owners[targetURL.lastPathComponent] {
                        vettedItems.append(EvaluatedItem(
                            footprintItem: item.footprintItem,
                            selection: .excluded(reason: "Shared with \(other)."),
                            costOfError: item.costOfError
                        ))
                        continue
                    }
                    if !groupClaims.complete {
                        vettedItems.append(EvaluatedItem(
                            footprintItem: item.footprintItem,
                            selection: .excluded(reason: "Shared ownership could not be checked."),
                            costOfError: item.costOfError
                        ))
                        continue
                    }
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
            vettedItems.append(item)
        }

        return EvaluatedFootprint(
            identity: footprint.identity, items: vettedItems, completeness: footprint.completeness,
            survivingCopies: survivingCopies
        )
    }

    /// The installed application an identifier-named item belongs to, when
    /// that application's identifier is more specific than this one's.
    ///
    /// Prefix rules take `com.google.Chrome.canary.plist` for Chrome,
    /// because it begins with Chrome's identifier and a dot. It is Chrome
    /// Canary's, and Canary is still installed.
    static func namedFor(_ url: URL, among others: [String: String], besides identity: Identity) -> String? {
        var name = url.lastPathComponent.lowercased()
        if name.hasPrefix(".") { name.removeFirst() }
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
    private func otherApplications(besides identity: Identity) async -> [Identity] {
        let root = root
        return await Task.detached {
            let subject = identity.bundlePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            var found: [Identity] = []
            for bundle in InstalledBundleInventory.read(in: root).bundles {
                // Its own parts are not somebody else.
                let path = bundle.resolvingSymlinksInPath().path
                if let subject, path == subject || path.hasPrefix(subject + "/") { continue }
                let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
                guard let identifier = info?["CFBundleIdentifier"] as? String else { continue }
                found.append(Identity(bundleID: identifier, name: bundle.deletingPathExtension().lastPathComponent,
                                      bundlePath: path))
            }
            return found
        }.value
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

    private static func isGroupPath(_ url: URL) -> Bool {
        url.path.contains("/Group Containers/") || url.path.contains("/Application Scripts/")
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
