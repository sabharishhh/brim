import BrimCore
import Foundation

/// An app's footprint grouped by what removing it costs the person, which
/// is the question they are asking: not which mechanism found a file, but
/// whether they lose their settings, their data, or nothing that will not
/// come back by itself.
public enum FootprintLoss: String, CaseIterable, Sendable {
    case app
    case data
    case settings
    case rebuilds
    case background
    case other

    public var title: String {
        switch self {
        case .app: "The app"
        case .data: "Data"
        case .settings: "Settings"
        case .rebuilds: "Rebuilds by itself"
        case .background: "Runs in the background"
        case .other: "Other"
        }
    }

    public static func of(_ item: FootprintItem) -> FootprintLoss {
        let url = item.evidence.url
        let path = url.path
        // An identifier can end in ".app", and the folders named for it sit
        // in the Library: `Containers/io.getpurge.app` is data, not the app.
        if url.pathExtension == "app", !path.contains("/Library/") {
            return .app
        }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") {
            return .background
        }
        // A sandboxed app's scripts folder and its autosaved documents are its
        // data. WhatsApp's nine Application Scripts folders sat in Other,
        // under a group that says nothing about what removing them costs.
        if path.contains("/Library/Application Scripts/") || path.contains("/Library/Autosave Information/") {
            return .data
        }
        // Settings kept the cross-platform way, outside the Library folder.
        if path.contains("/.config/") {
            return .settings
        }
        let domain = LeftoverDomain.of(url)
        switch domain {
        case .preferences: return .settings
        case .launchAgent: return .background
        case .applicationSupport, .container, .groupContainer, .webData: return .data
        case .other: return .other
        default: return domain.isRegenerated ? .rebuilds : .other
        }
    }

    /// The footprint in the order a person weighs it, largest first inside
    /// each group, empty groups left out.
    public static func arrange(_ footprint: Footprint) -> [ItemGroup<FootprintItem>] {
        let buckets = Dictionary(grouping: footprint.items, by: of)
        return allCases.compactMap { loss in
            guard let items = buckets[loss], !items.isEmpty else { return nil }
            return ItemGroup(
                id: loss.rawValue, title: loss.title, items: items.sorted { $0.sizeBytes > $1.sizeBytes }
            )
        }
    }
}
