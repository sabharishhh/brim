import Foundation

public struct FootprintItem: Codable, Equatable, Sendable {
    public let evidence: Evidence
    public let sizeBytes: Int64
    public let capability: Capability
    
    public init(evidence: Evidence, sizeBytes: Int64, capability: Capability) {
        self.evidence = evidence
        self.sizeBytes = sizeBytes
        self.capability = capability
    }
}

public struct Footprint: Codable, Equatable, Sendable {
    public let identity: Identity
    public let items: [FootprintItem]
    public var totalSizeBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }
    
    public init(identity: Identity, items: [FootprintItem]) {
        self.identity = identity
        self.items = items
    }
}
