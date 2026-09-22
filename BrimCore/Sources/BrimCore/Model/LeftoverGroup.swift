import Foundation

/// Everything one piece of software left behind, as a single thing.
///
/// The flat list showed `Codex` twice — once for `Application Support` and
/// once for `Caches` — with no indication they were the same software, and
/// the same for every vendor with more than one directory. A user cannot
/// reason about "is this needed" one path at a time; the question is about
/// the application, and the answer is the set of places it touched.
public struct LeftoverGroup: Identifiable, Sendable, Equatable {

    /// What to call this on screen.
    public let displayName: String
    /// The bundle identifier, where one was resolved.
    public let identifier: String?
    public let items: [Leftover]
    /// The key `groupedByOwner()` bucketed this group under.
    ///
    /// `id` used to be re-derived from `identifier ?? displayName`, and two
    /// genuinely different groups only ever share a display name for the
    /// same reason they needed grouping in the first place: neither carries
    /// a bundle identifier strong enough to tell them apart on its own.
    /// Seven distinct broken symlinks all pointing into a removed Docker,
    /// each its own group with one item, all displaying "Docker.app", all
    /// landing on the identical re-derived id `"docker.app"` — SwiftUI's
    /// list identity then treated all seven as one element wearing seven
    /// costumes, so ticking one toggled all seven and there was no way to
    /// tell whether they even lived in the same place. `groupKey` is the
    /// dictionary key `groupedByOwner()` already bucketed under, unique by
    /// construction, so `id` can no longer collide by accident.
    public let groupKey: String

    public var id: String { groupKey }

    // Everything below is derived from `items`, and every one of them used
    // to be a computed property.
    //
    // A group is immutable and built once a scan. A row reads six of these
    // each time SwiftUI draws it, and `domains` and `regeneratedBytes` each
    // walk every item calling `LeftoverDomain.of`, which is a substring
    // search over a path. Thirty visible rows cost 2.9ms per redraw to
    // answer questions whose answers could not have changed, and scrolling
    // the list was visibly rough because of it. Worked out once, in `init`.

    public let totalBytes: Int64

    /// A group is orphaned if anything in it is: the evidence that named a
    /// departed owner applies to the whole set.
    public let category: Leftover.Category

    /// Bytes that come back immediately, because the app rebuilds them.
    public let regeneratedBytes: Int64

    /// Bytes holding something the app would otherwise have remembered.
    public var meaningfulBytes: Int64 { totalBytes - regeneratedBytes }

    /// The sentence that decided the category, taken from the strongest
    /// item rather than repeated per row.
    public let evidence: String

    /// True when Brim can act on every part of it. A group that is partly
    /// blocked must not look actionable.
    public let isFullyActionable: Bool

    /// The one thing stopping the whole group, when one thing is stopping
    /// all of it.
    ///
    /// Said once here rather than on every row. Fourteen broken commands in
    /// `/usr/local/bin` share a single answer, and repeating it fourteen
    /// times is how the refusal that came *after* the attempt became nine
    /// hundred characters nobody could read. The group is also where a
    /// person can act on it: the checkbox that will not tick is this one.
    ///
    /// Nil when the group is removable, and nil when its items are blocked
    /// for different reasons, which the rows then have to say themselves.
    public let sharedObstacle: Capability?

    public let lastAccessed: Date?

    /// The domains this software touched, strongest meaning first, for the
    /// one-line summary under the name.
    public let domains: [LeftoverDomain]

    public init(displayName: String, identifier: String?, items: [Leftover], groupKey: String) {
        self.displayName = displayName
        self.identifier = identifier
        self.items = items
        self.groupKey = groupKey

        // One walk of `items`, not six, and `LeftoverDomain.of` once per
        // item rather than once per item per property per redraw.
        var total: Int64 = 0
        var regenerated: Int64 = 0
        var orderedDomains: [LeftoverDomain] = []
        var orphaned: String?
        var anyEvidence: String?
        var actionable = true
        var obstacles: Set<Capability> = []
        var accessed: Date?

        for item in items {
            total += item.size
            let domain = LeftoverDomain.of(item.url)
            if domain.isRegenerated { regenerated += item.size }
            if !orderedDomains.contains(domain) { orderedDomains.append(domain) }
            if item.category == .orphaned, orphaned == nil { orphaned = item.evidence }
            if anyEvidence == nil { anyEvidence = item.evidence }
            if item.capability != .ok { actionable = false }
            obstacles.insert(item.capability)
            if let date = item.lastAccessed, date > (accessed ?? .distantPast) { accessed = date }
        }

        self.totalBytes = total
        self.regeneratedBytes = regenerated
        self.domains = orderedDomains.sorted { !$0.isRegenerated && $1.isRegenerated }
        self.category = orphaned == nil ? .unclaimed : .orphaned
        self.evidence = orphaned ?? anyEvidence ?? ""
        self.isFullyActionable = actionable
        self.lastAccessed = accessed
        self.sharedObstacle = {
            guard obstacles.count == 1, let only = obstacles.first, only != .ok else { return nil }
            return only
        }()
    }

    /// What a screen reader should say for this entry.
    ///
    /// The row is built from a name, a lock, a size, a count, up to four
    /// capsules and a warning, and a reader was handed all of them as
    /// unrelated fragments. The size is carried as the value rather than
    /// the label, so the name and the consequence come first.
    public var spokenDescription: String {
        var parts = [displayName]
        parts.append(items.count == 1 ? "one location" : "\(items.count) locations")
        parts.append(category == .orphaned ? "orphaned" : "unclaimed")
        if !isFullyActionable { parts.append("Partly in use, so it cannot all be removed") }
        if meaningfulBytes > 0 {
            parts.append("some of this is what the application remembered about you")
        }
        parts.append(evidence)
        return SpokenText.sentences(parts)
    }
}

public extension Array where Element == Leftover {

    /// Collapses leftovers into one entry per piece of software.
    ///
    /// Keyed on the bundle identifier when the scan resolved one, and on the
    /// directory name otherwise — which is what merges
    /// `Application Support/Codex` with `Caches/Codex`, since neither
    /// carries an identifier and both are named for the same tool.
    func groupedByOwner() -> [LeftoverGroup] {
        // Every name a leftover answers to, joined up.
        //
        // Keying on the single strongest name split software that resolves
        // unevenly. Warp appeared twice on a real Mac, once from
        // `Application Scripts/2BBY89MBSN.dev.warp` and once from
        // `Group Containers/2BBY89MBSN.dev.warp`. Both resolved the owner
        // name "Warp"; only one of them also resolved a bundle identifier.
        // The identifier wins the key, so one landed under the identifier
        // and the other under "warp", and the list showed one product as two
        // rows of one location each, both called Warp.
        //
        // Joining them is the whole fix: a leftover carrying both an
        // identifier and a name is evidence that those two names are the same
        // software, so anything filed under either belongs in one group.
        var parent: [String: String] = [:]

        func find(_ key: String) -> String {
            var root = key
            while let next = parent[root], next != root { root = next }
            var walk = key
            while let next = parent[walk], next != root {
                parent[walk] = root
                walk = next
            }
            return root
        }

        func union(_ a: String, _ b: String) {
            let rootA = find(a), rootB = find(b)
            if rootA != rootB { parent[rootB] = rootA }
        }

        for leftover in self {
            let keys = Self.groupingKeys(for: leftover)
            for key in keys where parent[key] == nil { parent[key] = key }
            guard let first = keys.first else { continue }
            for other in keys.dropFirst() { union(first, other) }
        }

        var order: [String] = []
        var buckets: [String: [Leftover]] = [:]

        for leftover in self {
            guard let key = Self.groupingKeys(for: leftover).first else { continue }
            let root = find(key)
            if buckets[root] == nil { order.append(root) }
            buckets[root, default: []].append(leftover)
        }

        return order.compactMap { key -> LeftoverGroup? in
            guard let items = buckets[key], let first = items.first else { return nil }
            // Prefer a resolved bundle identifier for the subtitle, and the
            // most human of the available names for the title.
            let identifier = items.compactMap { $0.potentialOwner?.bundleID }.first
            let name = items
                .compactMap { $0.potentialOwner?.name }
                .first { !$0.isEmpty } ?? first.url.deletingPathExtension().lastPathComponent
            return LeftoverGroup(displayName: name, identifier: identifier, items: items, groupKey: key)
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    /// Bucketed on the strongest shared thing Brim already knows about the
    /// owner, not on the leftover's own file name.
    ///
    /// A real bundle identifier wins outright. Short of one, `potentialOwner`
    /// already carries the best name Brim resolved for this item, a broken
    /// symlink's target, a matched Homebrew cask, and that name is exactly
    /// what should merge several paths into one piece of software. Falling
    /// back to the item's own file name only happens when nothing was
    /// resolved at all, which is the original motivating case: neither
    /// `Application Support/Codex` nor `Caches/Codex` carries an identifier,
    /// so both fall through to "codex", their own shared name, and still
    /// merge correctly. What changed is that seven broken symlinks named
    /// `docker`, `kubectl`, `cagent` and so on, each pointing into the same
    /// removed Docker, used to bucket into seven different keys because
    /// each symlink's own name is different, only to display under the
    /// identical resolved owner name and collide on `LeftoverGroup.id` as a
    /// result. Grouping on the resolved name instead merges them honestly,
    /// into one row saying seven locations, matching what the row already
    /// claims about being organised by software rather than by path.
    /// Every name this one leftover answers to, strongest first.
    ///
    /// More than one, because a leftover that resolves both an identifier and
    /// a name is the evidence that ties those two names together. The file's
    /// own name is only a key when nothing was resolved at all, which is the
    /// original case: neither `Application Support/Codex` nor `Caches/Codex`
    /// carries an identifier, so both fall through to "codex" and merge.
    static func groupingKeys(for leftover: Leftover) -> [String] {
        var keys: [String] = []
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
