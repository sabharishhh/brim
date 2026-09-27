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

        for item in footprint.items {
            // Unticked rows can be promoted by the planner. Veto them now too.
            if case .excluded = item.selection {
                vettedItems.append(item)
                continue
            }
            do {
                let targetURL = item.footprintItem.evidence.url
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

                if let sharedWith = await checkSharedClaims(for: targetURL, identity: footprint.identity, resolver: resolver) {
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
            identity: footprint.identity, items: vettedItems, completeness: footprint.completeness
        )
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
                if bundle.resolvingSymlinksInPath().path == subject { continue }
                if budget.hasRunOut { complete = false; break }
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
        if let resolvedID = resolved.bundleID, let footprintID = identity.bundleID, resolvedID != footprintID {
            return resolved
        }

        return nil
    }
}
