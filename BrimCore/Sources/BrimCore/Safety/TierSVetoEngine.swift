import Foundation

public struct TierSVetoEngine: Sendable {
    private let root: FileSystemRoot

    public init(root: FileSystemRoot) {
        self.root = root
    }

    public func applyVeto(to footprint: EvaluatedFootprint) async -> EvaluatedFootprint {
        var vettedItems = [EvaluatedItem]()
        let groups = Set(footprint.identity.searchGroupContainers)
        let hasGroupTarget = footprint.items.contains { item in
            groups.contains(item.footprintItem.evidence.url.lastPathComponent)
                && (item.footprintItem.evidence.url.path.contains("/Group Containers/")
                    || item.footprintItem.evidence.url.path.contains("/Application Scripts/"))
        }
        let groupClaims = hasGroupTarget
            ? await otherGroupClaims(besides: footprint.identity) : (owners: [String: Identity](), complete: true)

        for item in footprint.items {
            if case .selected = item.selection {
                let targetURL = item.footprintItem.evidence.url
                let isGroupPath = targetURL.path.contains("/Group Containers/")
                    || targetURL.path.contains("/Application Scripts/")
                if groups.contains(targetURL.lastPathComponent), isGroupPath {
                    if let other = groupClaims.owners[targetURL.lastPathComponent] {
                        vettedItems.append(EvaluatedItem(
                            footprintItem: item.footprintItem,
                            selection: .excluded(reason: "Shared with \(other.name)."),
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

                if let sharedWith = await checkSharedClaims(for: targetURL, identity: footprint.identity) {
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

    private func otherGroupClaims(besides identity: Identity) async -> (owners: [String: Identity], complete: Bool) {
        let directories = [root.url(for: .applications), root.url(for: .userApplications)]
        let resolver = IdentityResolver(root: root)
        var owners: [String: Identity] = [:]
        var complete = true
        for directory in directories {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            } catch {
                let failure = error as NSError
                let missing = failure.domain == NSCocoaErrorDomain
                    && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)
                if missing {
                    continue
                }
                complete = false
                continue
            }
            for name in names where name.hasSuffix(".app") {
                let other = await resolver.resolve(bundleURL: directory.appendingPathComponent(name))
                if other.bundlePath == identity.bundlePath {
                    continue
                }
                for group in other.groupContainers {
                    owners[group] = other
                }
            }
        }
        return (owners, complete)
    }

    private func checkSharedClaims(for url: URL, identity: Identity) async -> Identity? {
        // Cross-identity resolution
        // If the path resolves to an identity that is NOT the footprint's identity, it is shared/owned by someone else
        let resolver = IdentityResolver(root: root)
        let resolved = await resolver.resolve(bundleURL: url)
        if let resolvedID = resolved.bundleID, let footprintID = identity.bundleID, resolvedID != footprintID {
            return resolved
        }

        return nil
    }
}
