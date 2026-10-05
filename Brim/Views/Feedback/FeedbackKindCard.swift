import BrimUI
import SwiftUI

struct FeedbackKindCard: View {
    let kind: FeedbackKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: kind.symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(Palette.selected, in: .rect(cornerRadius: Metrics.rowRadius))
                VStack(alignment: .leading, spacing: 6) {
                    Text(kind.title).font(.headline)
                    Text(kind.subtitle)
                        .font(.callout)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(Palette.inkTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
            .padding(16)
            .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius))
            // The same answer to the pointer as every other card.
            .hoverLift()
        }
        .buttonStyle(.press)
        .accessibilityLabel(kind.title)
        .accessibilityHint("Opens the feedback window")
    }
}
