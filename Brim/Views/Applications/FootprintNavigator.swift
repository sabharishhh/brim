import BrimUI
import SwiftUI

/// Equal navigation segments, never a chart of proportions or disk savings.
struct FootprintNavigator: View {
    let sections: [FootprintSection]
    let selected: FootprintLoss
    let select: (FootprintLoss, Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(sections) { section in
                segment(section)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Footprint groups")
    }

    /// Rows of equal groups with no orphan: four groups are two by two,
    /// not three and one left hanging.
    private var columns: Int {
        sections.count == 4 ? 2 : max(1, min(sections.count, 3))
    }

    private func segment(_ section: FootprintSection) -> some View {
        let isSelected = selected == section.loss
        return Button {
            select(section.loss, true)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: section.loss.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.inkSecondary))
                Text(section.loss.navigationTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(section.locations.count == 1 ? "1 location" : "\(section.locations.count) locations")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Palette.selected : Palette.surface,
                        in: .rect(cornerRadius: Metrics.rowRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.rowRadius)
                    .strokeBorder(Palette.inkSecondary.opacity(contrast == .increased ? 0.7 : 0), lineWidth: 1)
            }
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.tint)
                    .frame(height: 2)
                    .padding(.horizontal, 10)
                    .scaleEffect(x: isSelected ? 1 : 0, y: 1, anchor: .leading)
                    .opacity(isSelected ? 1 : 0)
                    .animation(reduceMotion ? nil : Motion.acknowledge, value: isSelected)
            }
            .contentShape(.rect(cornerRadius: Metrics.rowRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(section.loss.navigationTitle), \(section.locations.count) locations")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Show found locations in this group")
        .onKeyPress(keys: [.return, .space]) { _ in
            select(section.loss, false)
            return .handled
        }
    }
}
