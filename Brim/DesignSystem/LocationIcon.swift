import BrimCore
import BrimUI
import SwiftUI

/// What a location is, drawn so it reads at a glance in a review: an
/// application by its own icon, everything else by the kind of thing it
/// is. Finder's folder and document icons made every row look the same.
struct LocationIcon: View {
    let url: URL
    var size: CGFloat = 22

    var body: some View {
        if ["app", "appex", "prefpane", "plugin", "bundle"].contains(url.pathExtension.lowercased()),
           FileManager.default.fileExists(atPath: url.path) {
            BrimIcon(source: .finder(url), size: size)
        } else {
            Image(systemName: Self.symbol(for: url))
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: size, height: size)
                .background(Palette.well, in: .rect(cornerRadius: size * 0.25))
                .accessibilityHidden(true)
        }
    }

    static func symbol(for url: URL) -> String {
        if url.path.contains("/LaunchAgents/") || url.path.contains("/LaunchDaemons/") { return "clock.arrow.circlepath" }
        if url.path.contains("/var/db/receipts/") { return "shippingbox" }
        if url.path.hasPrefix("/usr/local/bin") || url.path.contains("/.local/bin") { return "terminal" }
        switch LeftoverDomain.of(url) {
        case .cache, .darwinPerUser: return "arrow.triangle.2.circlepath"
        case .applicationSupport: return "folder"
        case .preferences: return "slider.horizontal.3"
        case .logs: return "doc.text"
        case .savedState: return "macwindow"
        case .webData: return "globe"
        case .container, .groupContainer: return "square.stack.3d.up"
        case .launchAgent: return "clock.arrow.circlepath"
        case .other:
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            return isFolder.boolValue ? "folder" : "doc"
        }
    }
}
