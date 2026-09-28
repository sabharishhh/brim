import BrimCore
import Foundation

/// What macOS records this application as having written, where it is also
/// named for the application (Tier B).
///
/// Since Ventura, a file created by an application that came through
/// Gatekeeper carries `com.apple.provenance`, and the application's own
/// bundle carries the same value. That is the system's record of who wrote
/// something, which no name can give. ChatGPT's uninstall claimed 1.6 GB
/// and left 2.9 GB: `~/.codex`, `~/.cache/codex-runtimes` and folders called
/// `Codex` were all matched on a name or not at all, while every one of
/// them carried ChatGPT's provenance and a tool's folder beside them did not.
///
/// **Provenance alone is not ownership.** A process an application starts
/// inherits its provenance, so an application that runs shell commands
/// stamps whatever those commands create, `~/.npm` included. So both have to
/// hold: the name ties the item to the application, and the provenance
/// proves the application wrote it. When another installed bundle carries
/// the same value and is named for the same item, the two cannot be told
/// apart and nothing is claimed.
///
/// Only the first level of the places applications keep data is read, so
/// this costs one listing and a few attribute reads per folder.
public struct ProvenanceSource: EvidenceSource {
    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        await scan(for: identity, in: root).evidence
    }

    public func scan(for identity: Identity, in root: FileSystemRoot) async -> EvidenceFindings {
        guard let bundlePath = identity.bundlePath,
              let stamp = Self.provenance(bundlePath) else { return EvidenceFindings(evidence: []) }
        let inventory = await Task.detached { InstalledBundleInventory.read(in: root) }.value
        let subject = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path
        // Bundles carrying the same value. One is enough to make the value
        // ambiguous for anything named for it too, and says nothing about
        // anything named only for this application.
        let resolver = IdentityResolver(root: root)
        var others: [Owner] = []
        for bundle in inventory.bundles where bundle.resolvingSymlinksInPath().path != subject
            && Self.provenance(bundle.path) == stamp {
            let other = await resolver.resolve(bundleURL: bundle)
            others.append(Owner(stamp: stamp, identifiers: other.searchBundleIdentifiers.map { $0.lowercased() },
                                names: Self.names(for: other)))
        }

        let identifiers = identity.searchBundleIdentifiers.map { $0.lowercased() }
        let names = Self.names(for: identity)
        let sentence = "macOS records that \(identity.name) created this, and it is named for it."
        var evidence: [Evidence] = []
        for (directory, hiddenOnly) in Self.places(in: root) {
            guard case let .listed(entries) = DirectoryEntries.read(directory) else { continue }
            for entry in entries where !hiddenOnly || entry.hasPrefix(".") {
                guard Self.isNamed(entry, identifiers: identifiers, names: names),
                      !others.contains(where: { Self.isNamed(entry, identifiers: $0.identifiers, names: $0.names) })
                else { continue }
                let url = directory.appendingPathComponent(entry)
                guard Self.provenance(url.path) == stamp else { continue }
                evidence.append(Evidence(url: url, tier: .B, mechanism: "ProvenanceSource",
                                         humanSentence: sentence))
            }
        }
        return EvidenceFindings(evidence: evidence)
    }

    /// Where applications keep their own data, and whether only hidden
    /// entries count there. The home folder itself holds the person's own
    /// things, so only its dot folders are considered.
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

    /// The application's names as a folder would spell them: its own name,
    /// the bundle's names, and the last label of its identifier, which is
    /// usually the product (`codex` in `com.openai.codex`). Component names
    /// are left out: Sparkle's `Updater` is in half the applications here.
    static func names(for identity: Identity) -> [String] {
        let generic: Set<String> = [
            "client", "desktop", "macos", "application", "helper", "agent", "launcher",
            "service", "electron", "main", "native", "mac", "app"
        ]
        let lastLabel = identity.bundleID?.split(separator: ".").last.map(String.init)
        let candidates = [identity.name, identity.bundleName, lastLabel].compactMap(\.self)
        var seen = Set<String>()
        return candidates.map { $0.lowercased() }
            .filter { $0.count >= 4 && !generic.contains($0) && seen.insert($0).inserted }
    }

    /// Named for the application: an identifier, or a name followed by a
    /// separator, as in `codex-runtimes` or `.codex`.
    static func isNamed(_ entry: String, identifiers: [String], names: [String]) -> Bool {
        let lowered = entry.lowercased()
        let visible = lowered.hasPrefix(".") ? String(lowered.dropFirst()) : lowered
        if identifiers.contains(where: { visible == $0 || visible.hasPrefix($0 + ".") }) {
            return true
        }
        return names.contains { name in
            visible == name || ["-", "_", ".", " "].contains { visible.hasPrefix(name + $0) }
        }
    }

    /// An installed application as provenance knows it.
    public struct Owner: Sendable {
        let stamp: Data
        let identifiers: [String]
        let names: [String]
    }

    /// Every installed application with a provenance value.
    ///
    /// Two bundles can share one: anything an application creates carries
    /// its value, bundles included. Claude Code's URL handler was created
    /// from inside Visual Studio Code and carries Visual Studio Code's, and
    /// a rule that gave up whenever a value was shared left all of Visual
    /// Studio Code's data unclaimed. Sharing is settled per item instead, in
    /// `owner(of:among:)`.
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
