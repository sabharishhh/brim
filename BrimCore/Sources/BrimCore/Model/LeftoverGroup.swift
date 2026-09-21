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

    public var id: String { (identifier ?? displayName).lowercased() }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    /// A group is orphaned if anything in it is: the evidence that named a
    /// departed owner applies to the whole set.
    public var category: Leftover.Category {
        items.contains { $0.category == .orphaned } ? .orphaned : .unclaimed
    }

    /// Bytes that come back immediately, because the app rebuilds them.
    public var regeneratedBytes: Int64 {
        items.filter { LeftoverDomain.of($0.url).isRegenerated }.reduce(0) { $0 + $1.size }
    }

    /// Bytes holding something the app would otherwise have remembered.
    public var meaningfulBytes: Int64 { totalBytes - regeneratedBytes }

    /// The sentence that decided the category, taken from the strongest
    /// item rather than repeated per row.
    public var evidence: String {
        items.first { $0.category == .orphaned }?.evidence
            ?? items.first?.evidence
            ?? ""
    }

    /// True when Brim can act on every part of it. A group that is partly
    /// blocked must not look actionable.
    public var isFullyActionable: Bool { items.allSatisfy { $0.capability == .ok } }

    public var lastAccessed: Date? { items.compactMap(\.lastAccessed).max() }

    /// The domains this software touched, strongest meaning first, for the
    /// one-line summary under the name.
    public var domains: [LeftoverDomain] {
        var seen: [LeftoverDomain] = []
        for domain in items.map({ LeftoverDomain.of($0.url) }) where !seen.contains(domain) {
            seen.append(domain)
        }
        return seen.sorted { !$0.isRegenerated && $1.isRegenerated }
    }

    public init(displayName: String, identifier: String?, items: [Leftover]) {
        self.displayName = displayName
        self.identifier = identifier
        self.items = items
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
        if !isFullyActionable { parts.append("Brim cannot remove all of it as it is running") }
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
        var order: [String] = []
        var buckets: [String: [Leftover]] = [:]

        for leftover in self {
            let key = Self.groupingKey(for: leftover)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(leftover)
        }

        return order.compactMap { key -> LeftoverGroup? in
            guard let items = buckets[key], let first = items.first else { return nil }
            // Prefer a resolved bundle identifier for the subtitle, and the
            // most human of the available names for the title.
            let identifier = items.compactMap { $0.potentialOwner?.bundleID }.first
            let name = items
                .compactMap { $0.potentialOwner?.name }
                .first { !$0.isEmpty } ?? first.url.deletingPathExtension().lastPathComponent
            return LeftoverGroup(displayName: name, identifier: identifier, items: items)
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    static func groupingKey(for leftover: Leftover) -> String {
        if let bundleID = leftover.potentialOwner?.bundleID, !bundleID.isEmpty {
            return bundleID.lowercased()
        }
        // Strip the extensions macOS appends per domain so the same owner
        // in two places lands in one bucket.
        var name = leftover.url.lastPathComponent
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.lowercased()
    }
}
