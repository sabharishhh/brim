import BrimCore
import Foundation

/// Age changes the review scope. It never supplies ownership or permission
/// to remove an artifact.
public enum DeveloperAgeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case olderThan30Days
    case olderThan90Days

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .all: "All caches"
        case .olderThan30Days: "Project builds older than 30 days"
        case .olderThan90Days: "Project builds older than 90 days"
        }
    }

    public func includes(_ cache: DeveloperCache, now: Date = Date()) -> Bool {
        guard self != .all else { return true }
        guard let lastBuilt = cache.lastBuilt, lastBuilt != .distantPast else { return false }
        let days = self == .olderThan30Days ? 30 : 90
        return now.timeIntervalSince(lastBuilt) >= Double(days) * 24 * 60 * 60
    }
}
