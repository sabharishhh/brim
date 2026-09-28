import Foundation

/// Keeps rows where they were for the length of a visit (plan §8, rule 6).
///
/// A rescan, a keep or a removal elsewhere can change how a group sorts,
/// and a row that moves under the pointer is how somebody ticks the wrong
/// thing. So the order a page first showed is remembered, rows keep those
/// positions within their groups, and anything that arrived since goes at
/// the end of its group, where its new marker says what it is. The order
/// settles the next time the page is opened.
///
/// Only the order within a group is held. Which group a row is in is a
/// fact about it, and a kept row belongs under Kept at once.
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
