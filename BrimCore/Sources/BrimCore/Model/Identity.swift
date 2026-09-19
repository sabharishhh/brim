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
    public let name: String
    
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
    
    public init(bundleID: String? = nil, teamID: String? = nil, name: String, version: String? = nil, isSandboxed: Bool = false, groupContainers: [String] = [], cdHash: String? = nil, launchdLabel: String? = nil, launchdProgramPath: String? = nil, packageIdentifier: String? = nil) {
        self.bundleID = bundleID
        self.teamID = teamID
        self.name = name
        self.version = version
        self.isSandboxed = isSandboxed
        self.groupContainers = groupContainers
        self.cdHash = cdHash
        self.launchdLabel = launchdLabel
        self.launchdProgramPath = launchdProgramPath
        self.packageIdentifier = packageIdentifier
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
