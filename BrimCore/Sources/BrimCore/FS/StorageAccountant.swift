import Foundation

public struct StorageAccountant: Sendable {
    public struct Accounting: Sendable {
        public let measurement: ArtifactSize
        public let reclaimable: Int64?
        public let pinned: Int64?
        public var logical: Int64 {
            measurement.logicalBytes
        }

        /// The aggregate walk can stop after the per-item measurements finish.
        /// Keep that gap alongside the total it produced and the original search gaps.
        public func applying(
            to footprint: Footprint, additionalCompleteness: ScanCompleteness = .complete
        ) -> Footprint {
            Footprint(
                identity: footprint.identity, items: footprint.items,
                logicalSizeBytes: logical, reclaimableSizeBytes: reclaimable,
                snapshotPinnedBytes: pinned,
                completeness: footprint.completeness.merging(measurement.completeness)
                    .merging(additionalCompleteness)
            )
        }
    }

    public init() {}

    /// Counts overlapping roots and hardlinked content once. Native file size
    /// evidence cannot establish per-extent clone sharing or snapshot retention.
    /// Consequently capacity recoverable from a removal remains unknown.
    @concurrent
    public func account(
        for items: [FootprintItem], budget: ScanBudget = ScanBudget(), maximumEntries: Int = 200_000
    ) async -> Accounting {
        guard !items.isEmpty else {
            return Accounting(measurement: ArtifactSize(state: .complete), reclaimable: 0, pinned: 0)
        }
        let size = ArtifactSizer.measure(
            roots: items.map(\.evidence.url), budget: budget, maximumEntries: maximumEntries
        )
        return Accounting(measurement: size, reclaimable: nil, pinned: nil)
    }
}
