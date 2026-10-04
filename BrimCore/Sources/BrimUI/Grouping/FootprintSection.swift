import BrimCore
import Foundation

/// One location can have several ownership records. Keep them together without
/// counting the path twice or discarding a Shared record behind stronger evidence.
public struct FootprintLocation: Identifiable, Equatable, Sendable {
    public let url: URL
    public let items: [FootprintItem]

    public var id: String {
        url.path
    }

    public var isShared: Bool {
        items.contains { $0.evidence.tier == .S }
    }

    public var isPartial: Bool {
        items.contains {
            $0.unreadableEntries > 0 || $0.sizeMeasurement.map { $0.state != .complete } == true
        }
    }

    /// Whether some record of this place has no finished measurement.
    public var isUnmeasured: Bool {
        items.contains { $0.sizeMeasurement.map { $0.state == .pending || $0.state == .unknown } == true }
    }

    /// Conflicting observations do not justify choosing the larger number.
    public var logicalBytes: Int64? {
        guard !isUnmeasured else { return nil }
        let sizes = Set(items.map(\.sizeBytes))
        guard sizes.count == 1, let bytes = sizes.first, bytes >= 0 else { return nil }
        return bytes
    }

    fileprivate init?(items: [FootprintItem]) {
        guard let first = items.first else { return nil }
        url = first.evidence.url.standardizedFileURL
        self.items = items.sorted {
            if $0.evidence.tier != $1.evidence.tier {
                return $0.evidence.tier.rank < $1.evidence.tier.rank
            }
            if $0.evidence.humanSentence != $1.evidence.humanSentence {
                return $0.evidence.humanSentence < $1.evidence.humanSentence
            }
            return $0.evidence.mechanism < $1.evidence.mechanism
        }
    }
}

/// Navigation by consequence, independent of ownership and removal eligibility.
/// Group counts describe locations, not proportions or reclaimable disk space.
public struct FootprintSection: Identifiable, Equatable, Sendable {
    public let loss: FootprintLoss
    public let locations: [FootprintLocation]
    public var id: String {
        loss.rawValue
    }

    public static func arrange(_ footprint: Footprint) -> [FootprintSection] {
        let buckets = Dictionary(grouping: footprint.items, by: FootprintLoss.of)
        let order: [FootprintLoss] = [.app, .settings, .data, .background, .rebuilds, .other]
        return order.compactMap { loss in
            guard let items = buckets[loss] else { return nil }
            let paths = Dictionary(grouping: items) { $0.evidence.url.standardizedFileURL.path }
            let locations = paths.values.compactMap { FootprintLocation(items: $0) }.sorted {
                if $0.logicalBytes != $1.logicalBytes {
                    return ($0.logicalBytes ?? -1) > ($1.logicalBytes ?? -1)
                }
                return $0.id < $1.id
            }
            return FootprintSection(loss: loss, locations: locations)
        }
    }
}
