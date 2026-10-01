import BrimUI
import SwiftUI

struct FeedbackKindCard: View {
    let kind: FeedbackKind
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: kind.symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(Palette.selected, in: .rect(cornerRadius: Metrics.rowRadius))
                    .offset(y: hovering && !reduceMotion ? -2 : 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text(kind.title).font(.headline)
                    Text(kind.subtitle)
                        .font(.callout)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(hovering ? Color.accentColor : Palette.inkTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
            .padding(16)
            .background(hovering ? Palette.hover : Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius))
        }
        .buttonStyle(.press)
        .onHover { hovering = $0 }
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: hovering)
        .accessibilityLabel(kind.title)
        .accessibilityHint("Opens the feedback window")
    }
}
