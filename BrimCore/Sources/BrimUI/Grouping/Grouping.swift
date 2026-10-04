import Foundation

/// A group of items in a collection, as a stack card draws it.
public struct ItemGroup<Item>: Identifiable {
    public let id: String
    public let title: String
    public var items: [Item]
    /// Groups inside this one, such as each developer inside Suites. The
    /// group's own `items` are every item of its subgroups, in their order.
    public var subgroups: [ItemGroup<Item>]
    public var startsCollapsed: Bool

    public init(
        id: String, title: String, items: [Item], subgroups: [ItemGroup<Item>] = [], startsCollapsed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.items = items
        self.subgroups = subgroups
        self.startsCollapsed = startsCollapsed
    }
}

/// One rule of a grouping: which items it takes and how it orders them.
public struct GroupRule<Item> {
    public let id: String
    public let title: String
    /// Starts collapsed whatever its position, for what belongs to macOS.
    public let collapsed: Bool
    public let matches: (Item) -> Bool
    public let order: (Item, Item) -> Bool

    public init(
        id: String, title: String, collapsed: Bool = false,
        matches: @escaping (Item) -> Bool, order: @escaping (Item, Item) -> Bool
    ) {
        self.id = id
        self.title = title
        self.collapsed = collapsed
        self.matches = matches
        self.order = order
    }
}

/// How every collection is organised before anyone searches it.
///
/// Each item lives in exactly one group, the first rule it matches, and
/// every other fact about it is a chip on its row. The order rules are
/// tried in is not the order groups are shown in: macOS's own things are
/// taken first, so nothing of Apple's is offered as unused, and shown last.
/// Empty groups are not shown. About four groups are open at once, which
/// is roughly what a person holds in mind (Cowan), and the rest start
/// collapsed.
public enum Grouping {
    public static let openAtOnce = 4

    /// - Parameters:
    ///   - rules: tried in this order; the first match takes the item.
    ///   - otherwise: takes whatever no rule did, so nothing is dropped.
    ///   - display: rule identifiers in the order groups are shown.
    ///     Rules it leaves out follow in the order they were tried.
    public static func assign<Item>(
        _ items: [Item], rules: [GroupRule<Item>], otherwise: GroupRule<Item>, display: [String] = []
    ) -> [ItemGroup<Item>] {
        let all = rules + [otherwise]
        var buckets = Array(repeating: [Item](), count: all.count)
        for item in items {
            let index = rules.firstIndex { $0.matches(item) } ?? rules.count
            buckets[index].append(item)
        }
        let groups = all.indices.compactMap { index -> ItemGroup<Item>? in
            guard !buckets[index].isEmpty else { return nil }
            let rule = all[index]
            return ItemGroup(
                id: rule.id, title: rule.title, items: buckets[index].sorted(by: rule.order),
                startsCollapsed: rule.collapsed
            )
        }
        return limitOpen(ordered(groups, display: display))
    }

    static func ordered<Item>(_ groups: [ItemGroup<Item>], display: [String]) -> [ItemGroup<Item>] {
        guard !display.isEmpty else { return groups }
        let rank = Dictionary(uniqueKeysWithValues: display.enumerated().map { ($1, $0) })
        return groups.enumerated().sorted {
            (rank[$0.element.id] ?? display.count + $0.offset, $0.offset)
                < (rank[$1.element.id] ?? display.count + $1.offset, $1.offset)
        }.map(\.element)
    }

    /// The first few groups open and the rest collapsed.
    public static func limitOpen<Item>(_ groups: [ItemGroup<Item>]) -> [ItemGroup<Item>] {
        var open = 0
        return groups.map { group in
            var group = group
            if !group.startsCollapsed {
                open += 1
                group.startsCollapsed = open > openAtOnce
            }
            return group
        }
    }
}
