import Foundation

public struct FootprintItem: Codable, Equatable, Sendable {
    public let evidence: Evidence
    public let sizeBytes: Int64
    public let capability: Capability
    /// How many entries under this location could not be read, and so are
    /// missing from `sizeBytes`. A total that is short by an unknown amount
    /// has to say so rather than look complete.
    public let unreadableEntries: Int

    public init(
        evidence: Evidence, sizeBytes: Int64, capability: Capability,
        unreadableEntries: Int = 0
    ) {
        self.evidence = evidence
        self.sizeBytes = sizeBytes
        self.capability = capability
        self.unreadableEntries = unreadableEntries
    }
}

public struct Footprint: Codable, Equatable, Sendable {
    public let identity: Identity
    public let items: [FootprintItem]
    
    public let logicalSizeBytes: Int64
    public let reclaimableSizeBytes: Int64
    public let snapshotPinnedBytes: Int64

    /// What the search could not reach. When this is not complete the
    /// safety engine takes everything out of the default selection: a
    /// footprint is a claim about what is there, and an unfinished
    /// search cannot support the claim.
    public let completeness: ScanCompleteness
    
    /// The logical total: what these files contain. Not what removing them
    /// gives back, which is `reclaimableSizeBytes`, and not what a snapshot
    /// is holding, which is `snapshotPinnedBytes`. Three different facts,
    /// and showing one where another is meant is how a cleaning utility
    /// ends up lying.
    public var totalSizeBytes: Int64 {
        return logicalSizeBytes
    }

    /// Entries Brim could not read, across every location. When this is
    /// non zero the total is a floor, not a measurement.
    public var unreadableEntries: Int {
        items.reduce(0) { $0 + $1.unreadableEntries }
    }
    
    public init(identity: Identity, items: [FootprintItem], logicalSizeBytes: Int64? = nil, reclaimableSizeBytes: Int64? = nil, snapshotPinnedBytes: Int64? = nil, completeness: ScanCompleteness = .complete) {
        self.identity = identity
        self.items = items
        self.completeness = completeness
        
        let calculatedLogical = logicalSizeBytes ?? items.reduce(0) { $0 + $1.sizeBytes }
        self.logicalSizeBytes = calculatedLogical
        
        // Defaults if not provided (e.g. from tests)
        self.reclaimableSizeBytes = reclaimableSizeBytes ?? calculatedLogical
        self.snapshotPinnedBytes = snapshotPinnedBytes ?? 0
    }
}
