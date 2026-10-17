import Foundation

public enum ArtifactKind: String, Codable, Equatable, Sendable {
    case application
    case commandLineTool
    case launchDaemon
    case launchAgent
    case packageReceipt
    case unknown
}

public struct Identity: Codable, Equatable, Hashable, Sendable {
    public let bundleID: String?
    public private(set) var teamID: String?
    /// The bundle's file name: what a person calls it, often not what it calls
    /// itself on disk.
    public let name: String
    /// `CFBundleName`, the name the bundle uses for itself and names its support
    /// and cache folders after. Visual Studio Code's is "Code".
    public let bundleName: String?

    // Extended App fields
    public let version: String?
    public let isSandboxed: Bool
    public let groupContainers: [String]
    public let cdHash: String?
    public private(set) var bundlePath: String?
    public private(set) var identitySurface: IdentitySurface?
    public private(set) var capabilitySurface: CapabilitySurface?

    // Launchd fields
    public let launchdLabel: String?
    public let launchdProgramPath: String?

    /// Receipt fields
    public let packageIdentifier: String?
    /// Every name Brim's history recorded for the application. Set for one
    /// that has been removed, whose bundle can no longer be read.
    public private(set) var recordedNames: [String]?

    public init(bundleID: String? = nil, teamID: String? = nil, name: String, bundleName: String? = nil, version: String? = nil, isSandboxed: Bool = false, groupContainers: [String] = [], cdHash: String? = nil, launchdLabel: String? = nil, launchdProgramPath: String? = nil, packageIdentifier: String? = nil, bundlePath: String? = nil, identitySurface: IdentitySurface? = nil, capabilitySurface: CapabilitySurface? = nil, recordedNames: [String]? = nil) {
        self.bundleID = bundleID
        self.teamID = teamID
        self.name = name
        self.bundleName = bundleName
        self.version = version
        self.isSandboxed = isSandboxed
        self.groupContainers = groupContainers
        self.cdHash = cdHash
        self.bundlePath = bundlePath
        self.identitySurface = identitySurface
        self.capabilitySurface = capabilitySurface
        self.launchdLabel = launchdLabel
        self.launchdProgramPath = launchdProgramPath
        self.packageIdentifier = packageIdentifier
        self.recordedNames = recordedNames.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Every name this application answers to on disk, in order, without
    /// duplicates or empties. One place, so uninstall and the leftovers sweep
    /// agree.
    public var searchNames: [String] {
        Self.distinct(ownNames + derivedNames + (identitySurface?.searchableNames ?? []))
    }

    /// `<name> Helper`, what Chromium and Electron call their helper processes,
    /// and what web storage is filed under when a helper has no bundle. Searched
    /// as the start of a name, never ticked.
    public var helperNames: [String] {
        ownNames.filter { !$0.lowercased().hasSuffix("helper") }.map { $0 + " Helper" }
    }

    /// What the application itself is called: its file, bundle and display
    /// names, its executable, and every name Brim recorded for it while
    /// installed, which matters once the bundle is gone. Not its helpers.
    public var ownNames: [String] {
        Self.distinct([name, bundleName].compactMap(\.self) + (identitySurface?.ownNames ?? [])
            + (recordedNames ?? []))
    }

    /// Names worked out rather than declared: the identifier's last label, and
    /// each name without a trailing platform word. SystemEQ for Mac
    /// (`com.denzam.SystemEQ`) keeps `Application Support/SystemEQ`.
    public var derivedNames: [String] {
        var keys = Set(ownNames.map(NameKey.of))
        let stems = ownNames.compactMap(Self.withoutPlatformWord)
        let candidates = stems + [productLabel].compactMap(\.self)
        return Self.distinct(candidates.filter { keys.insert(NameKey.of($0)).inserted })
    }

    /// Whether a folder in the app's own data folders is named for it clearly
    /// enough to remove with it by default: a declared name in any case or
    /// spacing, or a derived name that is not an ordinary word.
    public func isClearlyNamed(_ fileName: String) -> Bool {
        let key = NameKey.of(fileName)
        guard !key.isEmpty else { return false }
        if ownNames.contains(where: { NameKey.of($0) == key }) {
            return true
        }
        return derivedNames.contains { NameKey.of($0) == key && !NameKey.isOrdinaryWord($0) }
    }

    /// Words that say which platform or edition a name is for. Folders leave
    /// them off: `SystemEQ for Mac` keeps `SystemEQ`.
    static func withoutPlatformWord(_ name: String) -> String? {
        let words = name.split(separator: " ").map(String.init)
        for suffix in Self.platformSuffixes where words.count > suffix.count {
            let tail = words.suffix(suffix.count).map { $0.lowercased() }
            if tail == suffix {
                let stem = words.dropLast(suffix.count).joined(separator: " ")
                return NameKey.of(stem).count >= 3 ? stem : nil
            }
        }
        return nil
    }

    private static let platformSuffixes: [[String]] = [
        ["for", "mac"], ["for", "macos"], ["for", "os", "x"], ["for", "desktop"],
        ["mac"], ["macos"], ["desktop"], ["app"]
    ]

    private static func distinct(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { IdentitySurface.isPathComponent($0) && seen.insert($0).inserted }
    }

    /// The identifier's last label, the developer's own name for the product.
    /// Still a name match. Labels naming a kind of thing are left out.
    var productLabel: String? {
        guard let label = bundleID?.split(separator: ".").last.map(String.init),
              label.count >= 4, !Self.genericLabels.contains(label.lowercased()) else { return nil }
        return label
    }

    private static let genericLabels: Set<String> = [
        "app", "application", "desktop", "client", "macos", "helper", "agent", "launcher", "service",
        "electron", "main", "native", "beta", "release", "stable", "mac", "osx"
    ]

    public var searchBundleIdentifiers: [String] {
        Array(Set([bundleID].compactMap(\.self)
                + (identitySurface?.searchableBundleIdentifiers ?? [])))
            .filter(IdentitySurface.isPathComponent).sorted()
    }

    /// Whether an identifier is this application's own: its bundle identifier or
    /// one inside it (`com.microsoft.teams2.agent` in `com.microsoft.teams2`).
    /// A component in another namespace, such as a shared framework's, ships in
    /// other apps, so a match on it stays Tier C.
    public func ownsIdentifier(_ identifier: String) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        let own = bundleID.lowercased()
        let other = identifier.lowercased()
        return other == own || other.hasPrefix(own + ".")
    }

    /// Home dot folders the bundle declares, such as `.vscode`.
    public var searchHomeFolders: [String] {
        (identitySurface?.homeFolders ?? []).filter(IdentitySurface.isPathComponent)
    }

    public var searchGroupContainers: [String] {
        Array(Set(identitySurface?.groups ?? groupContainers))
            .filter(IdentitySurface.isPathComponent).sorted()
    }

    public func attaching(_ surface: IdentitySurface, capabilities: CapabilitySurface) -> Identity {
        var copy = self
        copy.bundlePath = surface.bundlePath
        copy.identitySurface = surface
        copy.capabilitySurface = capabilities
        copy.teamID = surface.components.first?.teamIdentifier
        return copy
    }

    /// Refresh discovered surfaces without losing the selected installation.
    public func withoutDerivedSurfaces() -> Identity {
        var copy = self
        copy.identitySurface = nil
        copy.capabilitySurface = nil
        return copy
    }
}

public struct ArtifactRef: Codable, Equatable, Sendable {
    public let url: URL
    public let kind: ArtifactKind
    public let identity: Identity

    public init(url: URL, kind: ArtifactKind, identity: Identity) {
        self.url = url
        self.kind = kind
        self.identity = identity
    }
}
