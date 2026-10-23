import BrimCore
import Foundation

/// What macOS records this application as having written, where the item
/// is also named for it (Tier B). A file created by an app that came
/// through Gatekeeper carries `com.apple.provenance`, as does the app's
/// bundle. Provenance alone is not ownership: processes an app starts
/// inherit it, so the name must tie the item to the app as well. When
/// another bundle with the same value is named for the item, nothing is
/// claimed. Only the first level of data folders is read.
public struct ProvenanceSource: EvidenceSource {
    private let budget: @Sendable () -> ScanBudget
    private let readProvenance: @Sendable (String) -> Data?

    public init(budget: @escaping @Sendable () -> ScanBudget = { ScanBudget() }) {
        self.budget = budget
        readProvenance = Self.provenance
    }

    init(
        budget: @escaping @Sendable () -> ScanBudget = { ScanBudget() },
        readProvenance: @escaping @Sendable (String) -> Data?
    ) {
        self.budget = budget
        self.readProvenance = readProvenance
    }

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        await scan(for: identity, in: root).evidence
    }

    public func scan(for identity: Identity, in root: FileSystemRoot) async -> EvidenceFindings {
        guard let bundlePath = identity.bundlePath,
              let stamp = readProvenance(bundlePath) else { return EvidenceFindings(evidence: []) }
        var search = DirectorySearch(budget: budget())
        let inventory = await Task.detached { InstalledBundleInventory.read(in: root) }.value
        let subject = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path
        // Bundles carrying the same value make it ambiguous for anything named for
        // them too, but say nothing about items named only for this app.
        let resolver = IdentityResolver(root: root)
        var others: [Owner] = []
        for bundle in inventory.bundles where bundle.resolvingSymlinksInPath().path != subject {
            guard search.canContinue(at: bundle) else { break }
            guard readProvenance(bundle.path) == stamp else { continue }
            let other = await resolver.resolve(bundleURL: bundle)
            others.append(Owner(stamp: stamp, identifiers: other.searchBundleIdentifiers.map { $0.lowercased() },
                                names: Self.names(for: other)))
        }

        let identifiers = identity.searchBundleIdentifiers.map { $0.lowercased() }
        let names = Self.names(for: identity)
        let sentence = "macOS records that \(identity.name) created this, and it is named for it."
        var evidence: [Evidence] = []
        for (directory, hiddenOnly) in Self.places(in: root) {
            for entry in search.entries(directory) where !hiddenOnly || entry.hasPrefix(".") {
                guard search.canContinue(at: directory) else { break }
                guard Self.isNamed(entry, identifiers: identifiers, names: names),
                      !others.contains(where: { Self.isNamed(entry, identifiers: $0.identifiers, names: $0.names) })
                else { continue }
                let url = directory.appendingPathComponent(entry)
                guard readProvenance(url.path) == stamp else { continue }
                evidence.append(Evidence(url: url, tier: .B, mechanism: "ProvenanceSource",
                                         humanSentence: sentence))
            }
        }
        return EvidenceFindings(evidence: evidence, completeness: inventory.completeness.merging(search.completeness))
    }

    /// Where applications keep their own data, and whether only hidden entries
    /// count there: in the home folder, only dot folders.
    static func places(in root: FileSystemRoot) -> [(URL, Bool)] {
        let library = root.url(for: .userLibrary)
        let home = library.deletingLastPathComponent()
        return [(home, true)]
            + [FileSystemRoot.Domain.userDotConfig, .userDotCache, .userDotLocalShare, .userDotLocalState,
               .userApplicationSupport, .userCaches, .userLogs, .darwinUserCache, .darwinUserTemp]
            .map { (root.url(for: $0), false) }
            + ["Sounds", "HTTPStorages", "WebKit", "Saved Application State"]
            .map { (library.appendingPathComponent($0), false) }
    }

    /// The application's names as a folder would spell them, including derived
    /// ones such as the identifier's last label. Component names are left out:
    /// a helper called `Updater` ships in many apps.
    static func names(for identity: Identity) -> [String] {
        let generic: Set = [
            "client", "desktop", "macos", "application", "helper", "agent", "launcher",
            "service", "electron", "main", "native", "mac", "app"
        ]
        var seen = Set<String>()
        return (identity.ownNames + identity.derivedNames).map { $0.lowercased() }
            .filter { $0.count >= 4 && !generic.contains($0) && seen.insert($0).inserted }
    }

    /// Named for the application: an identifier, the name in any case or
    /// spacing, or a name followed by a separator (`codex-runtimes`, `.codex`).
    static func isNamed(_ entry: String, identifiers: [String], names: [String]) -> Bool {
        let lowered = entry.lowercased()
        let visible = lowered.hasPrefix(".") ? String(lowered.dropFirst()) : lowered
        if identifiers.contains(where: { visible == $0 || visible.hasPrefix($0 + ".") }) {
            return true
        }
        let key = NameKey.of(visible)
        return names.contains { name in
            key == NameKey.of(name) || ["-", "_", ".", " "].contains { visible.hasPrefix(name + $0) }
        }
    }

    /// An installed application as provenance knows it.
    public struct Owner: Sendable {
        let stamp: Data
        let identifiers: [String]
        let names: [String]
    }

    /// Every installed application with a provenance value. Two bundles can
    /// share one, because anything an app creates carries its value, so sharing
    /// is settled per item in `owner(of:among:)`.
    public static func owners(of identities: [Identity]) -> [Owner] {
        identities.compactMap { identity in
            guard let path = identity.bundlePath, let stamp = provenance(path) else { return nil }
            return Owner(stamp: stamp, identifiers: identity.searchBundleIdentifiers.map { $0.lowercased() },
                         names: names(for: identity))
        }
    }

    /// The installed application that wrote this and that it is named for,
    /// when exactly one bundle with that value is named for it.
    public static func owner(of url: URL, among owners: [Owner]) -> Owner? {
        guard !owners.isEmpty, let stamp = provenance(url.path) else { return nil }
        return owner(named: url.lastPathComponent, stamp: stamp, among: owners)
    }

    static func owner(named name: String, stamp: Data, among owners: [Owner]) -> Owner? {
        let claimants = owners.filter { owner in
            owner.stamp == stamp && isNamed(name, identifiers: owner.identifiers, names: owner.names)
        }
        return claimants.count == 1 ? claimants[0] : nil
    }

    /// The raw `com.apple.provenance` value, without following a link.
    static func provenance(_ path: String) -> Data? {
        let name = "com.apple.provenance"
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size <= 64 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &buffer, size, 0, XATTR_NOFOLLOW)
        guard read == size else { return nil }
        return Data(buffer)
    }
}
