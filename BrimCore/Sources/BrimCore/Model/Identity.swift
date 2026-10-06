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
    /// The bundle's file name. `Visual Studio Code.app` gives "Visual Studio
    /// Code", which is what a person calls it and frequently not what it
    /// calls itself on disk.
    public let name: String
    /// `CFBundleName`, the name the bundle uses for itself, which is what
    /// it names its support and cache folders after.
    ///
    /// Visual Studio Code's is "Code". Reading only `name` left 143 MB in
    /// `Application Support/Code` out of its own uninstall, because the
    /// folder is named after this and nothing on the uninstall path read
    /// it. `LeftoversScanner` had already learned to, separately, which is
    /// exactly how the two halves came to disagree.
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

    /// Every name this application answers to on disk, in the order a
    /// person would expect to see them, without duplicates and without
    /// empties.
    ///
    /// One place, because the uninstall path and the leftovers sweep have
    /// to agree about this. They did not: the sweep read `CFBundleName` and
    /// the uninstall path did not, so the sweep correctly refused to offer
    /// up `Application Support/Code` while Visual Studio Code was installed
    /// and the uninstall correctly failed to remove it when it was not.
    public var searchNames: [String] {
        Self.distinct(ownNames + derivedNames + (identitySurface?.searchableNames ?? []))
    }

    /// `<name> Helper`, which is what Chromium and Electron call the
    /// processes they start, and what web storage is filed under when the
    /// helper has no bundle of its own: `ChatGPTHelper.binarycookies`.
    /// Searched for as the start of a name, never ticked.
    public var helperNames: [String] {
        ownNames.filter { !$0.lowercased().hasSuffix("helper") }.map { $0 + " Helper" }
    }

    /// What the application itself is called: its file, its bundle and
    /// display names and its executable, and every name Brim recorded for
    /// it while it was installed. Not its helpers.
    ///
    /// Recorded names matter once the bundle is gone. History kept one
    /// name per application, so after SystemEQ for Mac was removed the
    /// sweep knew only that, and nothing else it had answered to.
    public var ownNames: [String] {
        Self.distinct([name, bundleName].compactMap(\.self) + (identitySurface?.ownNames ?? [])
            + (recordedNames ?? []))
    }

    /// Names worked out from the others rather than declared: the last label
    /// of the identifier, and each name without a platform word at its end.
    /// SystemEQ for Mac is `com.denzam.SystemEQ` and kept its presets in
    /// `Application Support/SystemEQ`, which none of its declared names
    /// spells.
    public var derivedNames: [String] {
        var keys = Set(ownNames.map(NameKey.of))
        let stems = ownNames.compactMap(Self.withoutPlatformWord)
        let candidates = stems + [productLabel].compactMap(\.self)
        return Self.distinct(candidates.filter { keys.insert(NameKey.of($0)).inserted })
    }

    /// Whether a folder in the application's own data folders is named for
    /// it clearly enough to remove with it by default: a name it declares,
    /// in any case or spacing, or a derived name that is not an ordinary
    /// word. `Caches/Codex` beside ChatGPT, whose identifier ends in
    /// `codex`, is a word and stays a suggestion. `Application Support/
    /// SystemEQ` is not.
    public func isClearlyNamed(_ fileName: String) -> Bool {
        let key = NameKey.of(fileName)
        guard !key.isEmpty else { return false }
        if ownNames.contains(where: { NameKey.of($0) == key }) {
            return true
        }
        return derivedNames.contains { NameKey.of($0) == key && !NameKey.isOrdinaryWord($0) }
    }

    /// Words that say which platform or edition a name is for, not what it
    /// is. Developers leave them off the folders: `SystemEQ for Mac` keeps
    /// `SystemEQ`, `Docker Desktop` keeps `Docker`.
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

    /// The last label of the bundle identifier, which is the developer's own
    /// name for the product. A match on it is still a name match. Labels
    /// that name a kind of thing rather than a product are left out.
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

    /// Whether an identifier is this application's own: its bundle
    /// identifier, or one inside it, the way `com.microsoft.teams2.agent`
    /// is inside `com.microsoft.teams2`. Something named that way was named
    /// by the developer for this application, and is not a guess.
    ///
    /// A component in a different namespace, such as Sparkle's downloader
    /// or another product from the same vendor, is not: the same identifier
    /// ships in other applications, so a match on it stays Tier C.
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
