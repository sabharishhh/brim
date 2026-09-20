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
    
    public let logicalSizeBytes: Int64
    public let reclaimableSizeBytes: Int64
    public let snapshotPinnedBytes: Int64
    
    public var totalSizeBytes: Int64 {
        return logicalSizeBytes
    }
    
    public init(identity: Identity, items: [FootprintItem], logicalSizeBytes: Int64? = nil, reclaimableSizeBytes: Int64? = nil, snapshotPinnedBytes: Int64? = nil) {
        self.identity = identity
        self.items = items
        
        let calculatedLogical = logicalSizeBytes ?? items.reduce(0) { $0 + $1.sizeBytes }
        self.logicalSizeBytes = calculatedLogical
        
        // Defaults if not provided (e.g. from tests)
        self.reclaimableSizeBytes = reclaimableSizeBytes ?? calculatedLogical
        self.snapshotPinnedBytes = snapshotPinnedBytes ?? 0
    }
}
