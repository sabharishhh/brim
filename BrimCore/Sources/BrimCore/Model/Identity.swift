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

    public init(bundleID: String? = nil, teamID: String? = nil, name: String, bundleName: String? = nil, version: String? = nil, isSandboxed: Bool = false, groupContainers: [String] = [], cdHash: String? = nil, launchdLabel: String? = nil, launchdProgramPath: String? = nil, packageIdentifier: String? = nil, bundlePath: String? = nil, identitySurface: IdentitySurface? = nil, capabilitySurface: CapabilitySurface? = nil) {
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
        var seen = Set<String>()
        let names = ([name, bundleName] + (identitySurface?.names ?? []).map(Optional.some))
            .compactMap(\.self)
            .filter { IdentitySurface.isPathComponent($0) && seen.insert($0).inserted }
        // The label is often the name in another case, `obsidian` for
        // Obsidian, which says nothing new.
        guard let label = productLabel, IdentitySurface.isPathComponent(label),
              !names.contains(where: { $0.lowercased() == label.lowercased() }) else { return names }
        return Array(names.prefix(2)) + [label] + names.dropFirst(2)
    }

    /// The last label of the bundle identifier, which is the developer's own
    /// name for the product. SystemEQ for Mac is `com.denzam.SystemEQ` and
    /// kept its presets in `Application Support/SystemEQ`, which no name it
    /// displays would find. A match on it is still a name match. Labels that
    /// name a kind of thing rather than a product are left out.
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
