import Foundation

public struct FootprintItem: Codable, Equatable, Sendable {
    public let evidence: Evidence
    public let sizeBytes: Int64
    public let capability: Capability
    public let sizeMeasurement: ArtifactSize?
    public let artifactClassification: ArtifactClassification?
    /// How many entries under this location could not be read, and so are
    /// missing from `sizeBytes`. A total that is short by an unknown amount
    /// has to say so rather than look complete.
    public let unreadableEntries: Int

    public init(
        evidence: Evidence, sizeBytes: Int64, capability: Capability,
        unreadableEntries: Int = 0, sizeMeasurement: ArtifactSize? = nil,
        artifactClassification: ArtifactClassification? = nil
    ) {
        self.evidence = evidence
        self.sizeBytes = sizeBytes
        self.capability = capability
        self.unreadableEntries = unreadableEntries
        self.sizeMeasurement = sizeMeasurement
        self.artifactClassification = artifactClassification
    }
}

public struct Footprint: Codable, Equatable, Sendable {
    public let identity: Identity
    public let items: [FootprintItem]
    
    public let logicalSizeBytes: Int64
    public let reclaimableSizeBytes: Int64?
    public let snapshotPinnedBytes: Int64?

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
        
        let roots = Set(ArtifactSizer.minimalRoots(items.map(\.evidence.url)).map(\.path))
        var counted = Set<String>()
        let calculatedLogical = logicalSizeBytes ?? items.reduce(0) { total, item in
            let path = item.evidence.url.standardizedFileURL.path
            guard roots.contains(path), counted.insert(path).inserted else { return total }
            return total + item.sizeBytes
        }
        self.logicalSizeBytes = calculatedLogical
        
        // Per-extent sharing and snapshot retention are not measured by a size
        // walk. Missing evidence is unknown, rather than zero or the total.
        self.reclaimableSizeBytes = reclaimableSizeBytes
        self.snapshotPinnedBytes = snapshotPinnedBytes
    }
}
