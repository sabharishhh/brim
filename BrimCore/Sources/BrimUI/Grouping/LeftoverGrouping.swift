import BrimCore
import Foundation

/// The ways the Leftovers collection can be grouped. Smart answers "what
/// can safely go?", which is the question the page exists for.
public enum LeftoverGrouping: String, CaseIterable, Sendable {
    case smart
    case kind
    case size

    public var title: String {
        switch self {
        case .smart: "Smart"
        case .kind: "What It Is"
        case .size: "Size"
        }
    }
}

/// Groups leftovers, one owner per row.
public struct LeftoverGrouper {
    public init() {}

    /// How sure Brim is that a group belongs to what it is named after: a
    /// recorded owner, a name that is an app's identifier, or only a name.
    public static func confidence(_ group: LeftoverGroup) -> EvidenceTier {
        if group.category == .orphaned {
            return .A
        }
        return group.identifier == nil ? .C : .B
    }

    static func bySize(_ lhs: LeftoverGroup, _ rhs: LeftoverGroup) -> Bool {
        lhs.totalBytes > rhs.totalBytes
    }

    public func groups(
        _ groups: [LeftoverGroup], by grouping: LeftoverGrouping, isKept: @escaping (LeftoverGroup) -> Bool
    ) -> [ItemGroup<LeftoverGroup>] {
        // Kept and staying are taken first in every grouping and shown
        // last, collapsed: a decision already made and a thing Brim cannot
        // act on are not what the person came to look at.
        let settled = [
            GroupRule<LeftoverGroup>(
                id: "kept", title: "Kept", collapsed: true, matches: isKept, order: Self.bySize
            ),
            GroupRule(
                id: "staying", title: "Staying, needs an administrator", collapsed: true,
                matches: { !$0.isFullyActionable }, order: Self.bySize
            )
        ]
        let rest = GroupRule<LeftoverGroup>(
            id: "rest", title: "Owner unknown", matches: { _ in true }, order: Self.bySize
        )
        switch grouping {
        case .smart: return smart(groups, settled: settled, rest: rest)
        case .kind: return byKind(groups, settled: settled, rest: rest)
        case .size: return bySize(groups, settled: settled)
        }
    }

    private func smart(
        _ groups: [LeftoverGroup], settled: [GroupRule<LeftoverGroup>], rest: GroupRule<LeftoverGroup>
    ) -> [ItemGroup<LeftoverGroup>] {
        Grouping.assign(
            groups,
            rules: settled + [
                GroupRule(
                    id: "removed", title: "From apps you removed",
                    matches: { $0.category == .orphaned }, order: Self.bySize
                ),
                GroupRule(
                    id: "named", title: "Named after an app",
                    matches: { $0.identifier != nil }, order: Self.bySize
                )
            ],
            otherwise: rest,
            display: ["removed", "named", "rest", "staying", "kept"]
        )
    }

    private func byKind(
        _ groups: [LeftoverGroup], settled: [GroupRule<LeftoverGroup>], rest: GroupRule<LeftoverGroup>
    ) -> [ItemGroup<LeftoverGroup>] {
        let kinds = LeftoverDomain.allCases.map { domain in
            GroupRule<LeftoverGroup>(
                id: domain.rawValue, title: domain.groupTitle,
                matches: { $0.domains.first == domain }, order: Self.bySize
            )
        }
        return Grouping.assign(
            groups, rules: settled + kinds, otherwise: rest,
            display: kinds.map(\.id) + ["rest", "staying", "kept"]
        )
    }

    private func bySize(_ groups: [LeftoverGroup], settled: [GroupRule<LeftoverGroup>]) -> [ItemGroup<LeftoverGroup>] {
        let bands = [
            GroupRule<LeftoverGroup>(
                id: "large", title: "Larger than 1 GB", matches: { $0.totalBytes > 1_000_000_000 }, order: Self.bySize
            ),
            GroupRule(
                id: "medium", title: "100 MB to 1 GB", matches: { $0.totalBytes > 100_000_000 }, order: Self.bySize
            ),
            GroupRule(
                id: "small", title: "10 MB to 100 MB", matches: { $0.totalBytes > 10_000_000 }, order: Self.bySize
            )
        ]
        return Grouping.assign(
            groups, rules: settled + bands,
            otherwise: GroupRule(id: "tiny", title: "Smaller than 10 MB", matches: { _ in true }, order: Self.bySize),
            display: bands.map(\.id) + ["tiny", "staying", "kept"]
        )
    }
}

public extension LeftoverDomain {
    /// The domain as a group of rows: plural, and saying what comes back.
    var groupTitle: String {
        switch self {
        case .cache: "Caches, come back by themselves"
        case .applicationSupport: "App data"
        case .preferences: "Settings"
        case .logs: "Logs, come back by themselves"
        case .savedState: "Window state"
        case .webData: "Web data"
        case .container: "Sandbox containers"
        case .groupContainer: "Shared containers"
        case .launchAgent: "Background jobs"
        case .darwinPerUser: "Working files"
        case .other: "Other"
        }
    }
}
