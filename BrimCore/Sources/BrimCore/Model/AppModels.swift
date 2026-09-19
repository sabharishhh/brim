import Foundation

/// Represents the level of confidence for a piece of evidence belonging to an app.
public enum EvidenceTier: String, Codable, Equatable, Sendable {
    /// Cryptographically guaranteed or OS-level mapping (e.g. Receipt BOM, Sandbox container).
    case S
    /// Direct structural mapping (e.g. App bundle itself, matching bundle ID).
    case A
    /// High probability heuristic (e.g. Developer name matching, fuzzy app name match).
    case B
    /// Low probability / weak heuristic (e.g. generic folder with related cache).
    case C
}

/// Represents a single piece of evidence found on disk.
public struct Evidence: Codable, Equatable, Sendable {
    public let url: URL
    public let tier: EvidenceTier
    
    public init(url: URL, tier: EvidenceTier) {
        self.url = url
        self.tier = tier
    }
}

/// A protocol defining an abstract discovered Application.
public protocol AppArtifact: Sendable {
    var bundleID: String { get }
    var name: String { get }
    var evidence: [Evidence] { get }
}

/// The aggregated result of a filesystem scan.
public struct ScanResult: Sendable {
    public let apps: [any AppArtifact]
    
    public init(apps: [any AppArtifact]) {
        self.apps = apps
    }
}
