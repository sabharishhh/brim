import Foundation

/// Keeps rows where they were for the length of a visit: a row that moves
/// under the pointer is how someone ticks the wrong thing. Rows keep their
/// first positions within their groups, and anything new goes at the end of
/// its group. Only the order within a group is held; which group a row is
/// in is a fact about it.
public enum StableOrder {
    /// Each item's position, in the order the groups show them.
    public static func positions<Item: Identifiable>(_ groups: [ItemGroup<Item>]) -> [Item.ID: Int] {
        var positions: [Item.ID: Int] = [:]
        for (index, item) in groups.flatMap(\.items).enumerated() where positions[item.id] == nil {
            positions[item.id] = index
        }
        return positions
    }

    /// The groups with every remembered item back in its remembered order.
    public static func apply<Item: Identifiable>(
        _ groups: [ItemGroup<Item>], remembered: [Item.ID: Int]
    ) -> [ItemGroup<Item>] {
        guard !remembered.isEmpty else { return groups }
        return groups.map { group in
            var group = group
            let known = group.items.filter { remembered[$0.id] != nil }
                .sorted { (remembered[$0.id] ?? 0) < (remembered[$1.id] ?? 0) }
            let arrived = group.items.filter { remembered[$0.id] == nil }
            group.items = known + arrived
            return group
        }
    }
}
