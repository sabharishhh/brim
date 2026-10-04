import BrimUI
import SwiftUI

struct FeedbackWindowHeader: View {
    @Environment(FeedbackModel.self) private var feedback

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Palette.selected, in: .rect(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Feedback").font(.brimPageTitle)
                Text(feedback.usesRelay ? "A direct line to improve Brim" : "Compose here, share on GitHub")
                    .font(.callout)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
        }
        .padding(Metrics.pagePadding)
    }
}
