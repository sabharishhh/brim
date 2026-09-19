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
    
    public init(bundleID: String?, teamID: String?, name: String) {
        self.bundleID = bundleID
        self.teamID = teamID
        self.name = name
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
