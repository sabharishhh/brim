import BrimCore
import BrimUI
import SwiftUI

/// One installed app: icon, name, a line of facts, size. A fixed height,
/// so a long list is measured by arithmetic.
struct AppRow: View {
    let app: InstalledApplication
    /// "Opened 3 months ago", worked out once per load rather than per draw.
    let opened: String?
    let isSelected: Bool
    let select: () -> Void
    let remove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            BrimIcon(source: .bundle(app.url), badge: app.isSystemProtected ? .helper : nil)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text(facts)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                RowAction(symbol: "arrow.up.forward.app", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([app.url])
                }
                if !app.isSystemProtected {
                    RowAction(symbol: "trash", help: "Remove \(app.name)", action: remove)
                }
            }
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)

            Text(ByteText.short(app.bundleSizeBytes))
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.rowHeight)
        .background(highlight, in: .rect(cornerRadius: Metrics.rowRadius, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.name), \(facts), \(ByteText.short(app.bundleSizeBytes))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // The default action, so a press from VoiceOver or anything else
        // does what a click does. A named action alone left the row inert.
        .accessibilityAction(.default, select)
    }

    /// Developer and when it was last opened, the two facts that decide
    /// whether an app can go. The version is in the inspector.
    private var facts: String {
        [app.developer, opened ?? (app.isSystemProtected ? "Part of macOS" : nil)]
            .compactMap(\.self).joined(separator: " · ")
    }

    private var highlight: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(.tint.opacity(0.10))
        }
        return AnyShapeStyle(isHovering ? Palette.well : Color.clear)
    }
}
