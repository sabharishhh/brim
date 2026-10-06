import BrimCore
import Foundation

/// An app's footprint grouped by what removing it costs the person, which
/// is the question they are asking: not which mechanism found a file, but
/// whether they lose their settings, their data, or nothing that will not
/// come back by itself.
///
/// One classification from inspection through review to the result, so a
/// preferences file is under Settings in all three and a person can follow
/// it from why it is the app's to what happened to it.
public enum FootprintLoss: String, CaseIterable, Sendable {
    case app
    case data
    case settings
    case rebuilds
    case background
    /// What an installer recorded about the app. Not a file in a place a
    /// person reasons about, so it is named for what it is.
    case records
    case other

    /// The order the groups are shown in, everywhere.
    public static let displayOrder: [FootprintLoss] = [
        .app, .settings, .data, .background, .rebuilds, .records, .other
    ]

    public var title: String {
        switch self {
        case .app: "The app"
        case .data: "Data"
        case .settings: "Settings"
        case .rebuilds: "Rebuilds by itself"
        case .background: "Runs in the background"
        case .records: "Installer records"
        case .other: "Other"
        }
    }

    /// The short name on the group's button and heading.
    public var navigationTitle: String {
        switch self {
        case .app: "App"
        case .settings: "Settings"
        case .data: "Data"
        case .background: "Background"
        case .rebuilds: "Rebuilds"
        case .records: "Records"
        case .other: "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .app: "app"
        case .settings: "slider.horizontal.3"
        case .data: "folder"
        case .background: "gearshape.2"
        case .rebuilds: "arrow.trianglehead.2.clockwise.rotate.90"
        case .records: "shippingbox"
        case .other: "doc"
        }
    }

    public static func of(_ item: FootprintItem) -> FootprintLoss {
        of(url: item.evidence.url)
    }

    /// A plan step, which is sometimes not a file: forgetting an installer
    /// receipt names a package identifier.
    public static func of(_ step: Step) -> FootprintLoss {
        switch step.kind {
        case .forgetReceipt: .records
        case .unloadLaunchdJob: .background
        default: of(url: URL(fileURLWithPath: step.target))
        }
    }

    public static func of(url: URL) -> FootprintLoss {
        let path = url.path
        // An identifier can end in ".app", and the folders named for it sit
        // in the Library: `Containers/io.getpurge.app` is data, not the app.
        if url.pathExtension == "app", !path.contains("/Library/") {
            return .app
        }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") {
            return .background
        }
        if path.hasPrefix("/private/var/db/receipts/") || path.hasPrefix("/var/db/receipts/") {
            return .records
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
