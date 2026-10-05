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
    /// Command-click: mark this app with others for one review.
    var mark: (() -> Void)?
    /// Choosing with the Select button: the row shows a tick, and a click
    /// ticks it rather than opening it.
    var isChoosing = false

    /// Denser rows, from View ▸ Compact Rows.
    @SwiftUI.Environment(\.compactRows) private var compact

    var body: some View {
        HStack(spacing: 12) {
            if isChoosing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.inkTertiary))
                    .opacity(app.isSystemProtected ? 0.35 : 1)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            BrimIcon(
                source: .bundle(app.url),
                size: Metrics.rowIcon(compact: compact),
                badge: app.isSystemProtected ? .helper : nil
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                if !compact {
                    Text(facts)
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .lineLimit(1)

            Spacer(minLength: 8)

            if !isChoosing {
                HoverActions {
                    RowAction(symbol: "arrow.up.forward.app", help: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([app.url])
                    }
                }
            }

            Text(ByteText.short(app.bundleSizeBytes))
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkSecondary)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.rowHeight(compact: compact))
        .rowHighlight(isInspected: isSelected && !isChoosing, action: isChoosing ? (mark ?? select) : select,
                      commandAction: mark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.name), \(facts), \(ByteText.short(app.bundleSizeBytes))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // The default action, so a press from VoiceOver or anything else
        // does what a click does. A named action alone left the row inert.
        .accessibilityAction(.default, isChoosing ? (mark ?? select) : select)
    }

    /// Developer and when it was last opened, the two facts that decide
    /// whether an app can go. The version is in the inspector.
    private var facts: String {
        let place = app.enclosingApp.map { "Inside \($0)" }
        return [app.developer, place ?? opened ?? (app.isSystemProtected ? "Part of macOS" : nil)]
            .compactMap(\.self).joined(separator: " · ")
    }
}
