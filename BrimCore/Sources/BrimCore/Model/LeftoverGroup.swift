import Foundation

/// Everything one piece of software left behind, as one thing. People reason
/// about the application, not one path at a time.
public struct LeftoverGroup: Identifiable, Sendable, Equatable {
    /// What to call this on screen.
    public let displayName: String
    /// The bundle identifier, where one was resolved.
    public let identifier: String?
    public let items: [Leftover]
    /// The key `groupedByOwner()` bucketed this group under, unique by
    /// construction. An id derived from the display name collided: seven broken
    /// links to a removed Docker all became one list element, and ticking one
    /// ticked all seven.
    public let groupKey: String

    public var id: String {
        groupKey
    }

    // Everything below is derived from `items` once, in `init`. As computed
    // properties they were worked out on every redraw.

    public let totalBytes: Int64

    /// Orphaned if anything in it is: the evidence naming a departed owner
    /// applies to the whole set.
    public let category: Leftover.Category

    /// Bytes that come back immediately, because the app rebuilds them.
    public let regeneratedBytes: Int64

    /// Bytes holding something the app would otherwise have remembered.
    public var meaningfulBytes: Int64 {
        totalBytes - regeneratedBytes
    }

    /// The sentence that decided the category, taken from the strongest
    /// item rather than repeated per row.
    public let evidence: String

    /// True when Brim can act on every part of it; a partly blocked group must
    /// not look actionable.
    public let isFullyActionable: Bool

    /// The one thing stopping the whole group, said once here rather than on
    /// every row. Nil when the group is removable, or when items are blocked for
    /// different reasons, which the rows then say.
    public let sharedObstacle: Capability?

    public let lastAccessed: Date?
    /// When Brim last saw the app installed, where it knows.
    public let removedAt: Date?
    /// The installed app that replaced this one, only when every item in
    /// the group says the same. A group that disagrees makes no claim.
    public let replacedBy: Replacement?

    /// The domains this software touched, strongest meaning first, for the
    /// one-line summary under the name.
    public let domains: [LeftoverDomain]

    public init(displayName: String, identifier: String?, items: [Leftover], groupKey: String) {
        self.displayName = displayName
        self.identifier = identifier
        self.items = items
        self.groupKey = groupKey

        // One walk of `items`, calling `LeftoverDomain.of` once per item.
        var total: Int64 = 0
        var regenerated: Int64 = 0
        var orderedDomains: [LeftoverDomain] = []
        var orphaned: String?
        var anyEvidence: String?
        var actionable = true
        var obstacles: Set<Capability> = []
        var accessed: Date?
        var removed: Date?

        for item in items {
            total += item.size
            let domain = LeftoverDomain.of(item.url)
            if domain.isRegenerated {
                regenerated += item.size
            }
            if !orderedDomains.contains(domain) {
                orderedDomains.append(domain)
            }
            if item.category == .orphaned, orphaned == nil {
                orphaned = item.evidence
            }
            if anyEvidence == nil {
                anyEvidence = item.evidence
            }
            if !item.canBeRemovedByBrim {
                actionable = false
            }
            obstacles.insert(item.canBeRemovedByBrim ? .ok : item.capability)
            if let date = item.lastAccessed, date > (accessed ?? .distantPast) {
                accessed = date
            }
            if let date = item.removedAt, date > (removed ?? .distantPast) {
                removed = date
            }
        }

        totalBytes = total
        regeneratedBytes = regenerated
        domains = orderedDomains.sorted { !$0.isRegenerated && $1.isRegenerated }
        category = orphaned == nil ? .unclaimed : .orphaned
        evidence = orphaned ?? anyEvidence ?? ""
        isFullyActionable = actionable
        lastAccessed = accessed
        removedAt = removed
        let replacements = Set(items.map(\.replacedBy))
        replacedBy = replacements.count == 1 ? replacements.first ?? nil : nil
        sharedObstacle = Self.sharedObstacle(in: obstacles)
    }

    private static func sharedObstacle(in obstacles: Set<Capability>) -> Capability? {
        guard obstacles.count == 1, let only = obstacles.first, only != .ok else { return nil }
        return only
    }

    /// One sentence for VoiceOver. The size is the value, so the name and the
    /// consequence come first.
    public var spokenDescription: String {
        var parts = [displayName]
        parts.append(items.count == 1 ? "one location" : "\(items.count) locations")
        parts.append(category == .orphaned ? "orphaned" : "unclaimed")
        if !isFullyActionable {
            parts.append("Partly in use, so it cannot all be removed")
        }
        if meaningfulBytes > 0 {
            parts.append("some of this is what the application remembered about you")
        }
        parts.append(evidence)
        return SpokenText.sentences(parts)
    }
}

private struct OwnerAliases {
    let ambiguousNames: Set<String>

    init(items: [Leftover]) {
        var identifiersByName: [String: Set<String>] = [:]
        for item in items {
            if let identifier = item.potentialOwner?.bundleID, let name = item.potentialOwner?.name {
                identifiersByName[name.lowercased(), default: []].insert(identifier.lowercased())
            }
        }
        ambiguousNames = Set(identifiersByName.filter { $0.value.count > 1 }.keys)
    }

    func keys(for item: Leftover) -> [String] {
        let keys = [Leftover].groupingKeys(for: item)
        guard let name = item.potentialOwner?.name.lowercased(), ambiguousNames.contains(name) else {
            return keys
        }
        return item.potentialOwner?.bundleID == nil
            ? ["name:" + name] : keys.filter { $0 != name }
    }
}

public extension [Leftover] {
    /// Collapses leftovers into one entry per piece of software, keyed on the
    /// bundle identifier when there is one and the folder name otherwise, so
    /// `Application Support/Codex` and `Caches/Codex` merge.
    func groupedByOwner() -> [LeftoverGroup] {
        let aliases = OwnerAliases(items: self)
        // Every name a leftover answers to, joined. A leftover with both an
        // identifier and a name shows those are the same software, so anything
        // filed under either belongs in one group.
        var parent: [String: String] = [:]

        func find(_ key: String) -> String {
            var root = key
            while let next = parent[root], next != root {
                root = next
            }
            var walk = key
            while let next = parent[walk], next != root {
                parent[walk] = root
                walk = next
            }
            return root
        }

        func union(_ a: String, _ b: String) {
            let rootA = find(a), rootB = find(b)
            if rootA != rootB {
                parent[rootB] = rootA
            }
        }

        for leftover in self {
            let keys = aliases.keys(for: leftover)
            for key in keys where parent[key] == nil {
                parent[key] = key
            }
            guard let first = keys.first else { continue }
            for other in keys.dropFirst() {
                union(first, other)
            }
        }

        var order: [String] = []
        var buckets: [String: [Leftover]] = [:]

        for leftover in self {
            guard let key = aliases.keys(for: leftover).first else { continue }
            let root = find(key)
            if buckets[root] == nil {
                order.append(root)
            }
            buckets[root, default: []].append(leftover)
        }

        return order.compactMap { key -> LeftoverGroup? in
            buckets[key].flatMap { Self.group(key: key, items: $0) }
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    /// One group: a developer's under their name, otherwise the most human
    /// of the names the items resolved, with a bundle identifier beneath.
    private static func group(key: String, items: [Leftover]) -> LeftoverGroup? {
        guard let first = items.first else { return nil }
        if key.hasPrefix("vendor:") {
            let vendor = String(key.dropFirst("vendor:".count))
            return LeftoverGroup(displayName: OwnerNamespace.vendorDisplayName(vendor), identifier: nil,
                                 items: items, groupKey: key)
        }
        let identifier = items.compactMap { $0.potentialOwner?.bundleID }.first
        let name = items
            .compactMap { $0.potentialOwner?.name }
            .first { !$0.isEmpty } ?? first.url.deletingPathExtension().lastPathComponent
        return LeftoverGroup(displayName: name, identifier: identifier, items: items, groupKey: key)
    }

    /// Every name this leftover answers to, strongest first: a real bundle
    /// identifier, then the owner name Brim resolved (a broken link's target, a
    /// matched cask), and the file's own name only when nothing was resolved.
    /// Several links into one removed app then group as that app.
    static func groupingKeys(for leftover: Leftover) -> [String] {
        var keys: [String] = []
        // An unclaimed identifier is only a spelling from the file name. Keep one
        // product namespace together without joining every helper called
        // "Helper"; with nothing of the developer's installed, their leftovers are
        // one group.
        if leftover.category == .unclaimed, let vendor = leftover.vendor {
            return ["vendor:" + vendor]
        }
        if leftover.category == .unclaimed, let namespace = OwnerNamespace.key(for: leftover.url.lastPathComponent) {
            return [namespace]
        }
        if let bundleID = leftover.potentialOwner?.bundleID, !bundleID.isEmpty {
            keys.append(bundleID.lowercased())
        }
        if let name = leftover.potentialOwner?.name, !name.isEmpty {
            keys.append(name.lowercased())
        }
        guard keys.isEmpty else { return keys }

        // Strip the extensions macOS appends per domain so the same owner
        // in two places lands in one bucket.
        var name = leftover.url.lastPathComponent
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return [name.lowercased()]
    }

    /// The single strongest key, kept for callers that want one answer.
    static func groupingKey(for leftover: Leftover) -> String {
        groupingKeys(for: leftover).first ?? leftover.url.lastPathComponent.lowercased()
    }
}
