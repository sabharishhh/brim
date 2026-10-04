import BrimCore
import Foundation

/// The ways the Apps collection can be grouped. Smart is the default: it
/// answers "which of these could go?", which is why people open the list.
public enum AppGrouping: String, CaseIterable, Sendable {
    case smart
    case developer
    case source
    case category
    case lastOpened
    case size
    case name

    public var title: String {
        switch self {
        case .smart: "Smart"
        case .developer: "Developer"
        case .source: "Source"
        case .category: "Category"
        case .lastOpened: "Last Opened"
        case .size: "Size"
        case .name: "Name"
        }
    }
}

/// Groups installed applications.
public struct AppGrouper {
    public static let recentDays = 14
    public static let unusedDays = 90
    public static let everydayDays = 7
    public static let largeBytes: Int64 = 1_000_000_000

    public let now: Date

    public init(now: Date = .now) {
        self.now = now
    }

    public func groups(_ apps: [InstalledApplication], by grouping: AppGrouping) -> [ItemGroup<InstalledApplication>] {
        switch grouping {
        case .smart: smart(apps)
        case .developer: byKey(apps, key: { $0.developer }, missing: "Unknown developer", appleLast: true)
        case .source: bySource(apps)
        case .category:
            byKey(apps, key: { $0.category.map(ApplicationFacts.categoryTitle) }, missing: "No category")
        case .lastOpened: byLastOpened(apps)
        case .size: bySize(apps)
        case .name:
            Grouping.assign(apps, rules: [], otherwise: GroupRule(
                id: "all", title: "All apps", matches: { _ in true }, order: Self.byName
            ))
        }
    }

    // MARK: - Facts

    private func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86400)
    }

    /// Unopened for three months, as far as can be proved. An app with no
    /// Spotlight record at all is never counted: that is "did not look",
    /// and calling it unused would be a claim nothing supports.
    func isUnused(_ app: InstalledApplication) -> Bool {
        if app.isMigratedAndUnopened {
            return true
        }
        if let lastOpened = app.lastOpened {
            return lastOpened < daysAgo(Self.unusedDays)
        }
        // Indexed and never opened: unused since it arrived.
        if let addedAt = app.addedAt {
            return addedAt < daysAgo(Self.unusedDays)
        }
        return false
    }

    public func isRecentlyInstalled(_ app: InstalledApplication) -> Bool {
        app.installedAt.map { $0 >= daysAgo(Self.recentDays) } ?? false
    }

    func isEveryday(_ app: InstalledApplication) -> Bool {
        guard !app.isMigratedAndUnopened, let lastOpened = app.lastOpened else { return false }
        return lastOpened >= daysAgo(Self.everydayDays)
    }

    static func isApple(_ app: InstalledApplication) -> Bool {
        app.source == .apple || app.isSystemProtected
    }

    static func byName(_ lhs: InstalledApplication, _ rhs: InstalledApplication) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    static func bySizeDescending(_ lhs: InstalledApplication, _ rhs: InstalledApplication) -> Bool {
        lhs.bundleSizeBytes > rhs.bundleSizeBytes
    }

    // MARK: - Smart

    /// Two groups, by the one question that decides what can be done:
    /// the apps you installed, which Brim can remove, and the ones that
    /// cannot go, macOS's own and apps shipped inside another. Each is
    /// ordered by use, most recent first, so what you live in is at the top
    /// and what you have forgotten sinks.
    ///
    /// This replaced six smart groups (recently installed, unused, larger
    /// than 1 GB, suites, opened this week, everything else). Each was true
    /// and together they scattered one list across the page, with no group
    /// that answered what someone opens Apps to find.
    private func smart(_ apps: [InstalledApplication]) -> [ItemGroup<InstalledApplication>] {
        Grouping.assign(
            apps,
            rules: [
                GroupRule(id: "builtin", title: "Built in", matches: \.isSystemProtected, order: Self.byUse)
            ],
            otherwise: GroupRule(id: "yours", title: "Your apps", matches: { _ in true }, order: Self.byUse),
            display: ["yours", "builtin"]
        )
    }

    /// Most recently opened first. Apps Spotlight has no date for follow,
    /// by name, rather than being placed as though they were never used.
    static func byUse(_ lhs: InstalledApplication, _ rhs: InstalledApplication) -> Bool {
        switch (lhs.lastOpened, rhs.lastOpened) {
        case let (left?, right?): left > right
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): byName(lhs, rhs)
        }
    }

    /// The signing team when there is one, since two apps from one team
    /// are one developer whatever their names say.
    static func suiteKey(_ app: InstalledApplication) -> String? {
        app.identity.teamID ?? app.developer
    }

    static func suiteTitle(_ app: InstalledApplication) -> String {
        app.developer ?? app.identity.teamID ?? "Unknown developer"
    }

    // MARK: - Alternates

    private func byKey(
        _ apps: [InstalledApplication], key: (InstalledApplication) -> String?, missing: String, appleLast: Bool = false
    ) -> [ItemGroup<InstalledApplication>] {
        let buckets = Dictionary(grouping: apps) { key($0) ?? "" }
        let titles = buckets.keys.filter { !$0.isEmpty }.sorted { lhs, rhs in
            if appleLast, lhs == "Apple" || rhs == "Apple" {
                return rhs == "Apple" && lhs != "Apple"
            }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        var groups = titles.map { title in
            ItemGroup(
                id: title, title: title, items: buckets[title, default: []].sorted(by: Self.byName),
                startsCollapsed: appleLast && title == "Apple"
            )
        }
        if let unknown = buckets[""] {
            groups.append(ItemGroup(id: "missing", title: missing, items: unknown.sorted(by: Self.byName)))
        }
        return Grouping.limitOpen(groups)
    }

    private func bySource(_ apps: [InstalledApplication]) -> [ItemGroup<InstalledApplication>] {
        let order: [ApplicationSource] = [.appStore, .homebrew, .setapp, .direct, .apple]
        return Grouping.assign(
            apps,
            rules: order.map { source in
                GroupRule(
                    id: source.rawValue, title: source.title, collapsed: source == .apple,
                    matches: { $0.source == source }, order: Self.byName
                )
            },
            otherwise: GroupRule(id: "unknown", title: "Source not known", matches: { _ in true }, order: Self.byName)
        )
    }

    private func byLastOpened(_ apps: [InstalledApplication]) -> [ItemGroup<InstalledApplication>] {
        let recentFirst: (InstalledApplication, InstalledApplication) -> Bool = {
            ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast)
        }
        func openedSince(_ days: Int) -> (InstalledApplication) -> Bool {
            { app in
                !app.isMigratedAndUnopened && (app.lastOpened.map { $0 >= daysAgo(days) } ?? false)
            }
        }
        return Grouping.assign(
            apps,
            rules: [
                GroupRule(id: "week", title: "Opened this week", matches: openedSince(7), order: recentFirst),
                GroupRule(id: "month", title: "Opened this month", matches: openedSince(30), order: recentFirst),
                GroupRule(
                    id: "quarter", title: "Opened in the last 3 months", matches: openedSince(Self.unusedDays),
                    order: recentFirst
                ),
                GroupRule(id: "unused", title: "Not opened in 3 months", matches: isUnused, order: recentFirst),
                GroupRule(
                    id: "never", title: "Not opened yet", matches: { $0.lastOpened == nil && $0.addedAt != nil },
                    order: Self.byName
                )
            ],
            // No Spotlight record at all: Brim cannot say, which is its own
            // group rather than a guess in either direction.
            otherwise: GroupRule(
                id: "unknown", title: "No record of use", collapsed: true, matches: { _ in true }, order: Self.byName
            )
        )
    }

    private func bySize(_ apps: [InstalledApplication]) -> [ItemGroup<InstalledApplication>] {
        Grouping.assign(
            apps,
            rules: [
                GroupRule(
                    id: "large", title: "Larger than 1 GB", matches: { $0.bundleSizeBytes > Self.largeBytes },
                    order: Self.bySizeDescending
                ),
                GroupRule(
                    id: "medium", title: "100 MB to 1 GB", matches: { $0.bundleSizeBytes > 100_000_000 },
                    order: Self.bySizeDescending
                )
            ],
            otherwise: GroupRule(
                id: "small", title: "Smaller than 100 MB", matches: { _ in true }, order: Self.bySizeDescending
            )
        )
    }
}
