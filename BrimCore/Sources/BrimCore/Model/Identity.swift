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
    public let teamID: String?
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
    
    // Launchd fields
    public let launchdLabel: String?
    public let launchdProgramPath: String?
    
    // Receipt fields
    public let packageIdentifier: String?
    
    public init(bundleID: String? = nil, teamID: String? = nil, name: String, bundleName: String? = nil, version: String? = nil, isSandboxed: Bool = false, groupContainers: [String] = [], cdHash: String? = nil, launchdLabel: String? = nil, launchdProgramPath: String? = nil, packageIdentifier: String? = nil) {
        self.bundleID = bundleID
        self.teamID = teamID
        self.name = name
        self.bundleName = bundleName
        self.version = version
        self.isSandboxed = isSandboxed
        self.groupContainers = groupContainers
        self.cdHash = cdHash
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
        return [name, bundleName]
            .compactMap { $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
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
