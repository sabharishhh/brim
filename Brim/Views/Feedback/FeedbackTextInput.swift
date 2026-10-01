import SwiftUI

struct FeedbackTextInput: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let minimumHeight: CGFloat
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if text.count > limit - 200 {
                    Text("\(text.count) / \(limit)")
                        .font(.caption)
                        .foregroundStyle(text.count > limit ? Palette.caution : Palette.inkSecondary)
                }
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt)
                        .foregroundStyle(Palette.inkTertiary)
                        .padding(.horizontal, 9)
                        .padding(.top, 9)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .accessibilityLabel(title)
                    .accessibilityHint(prompt)
            }
            .frame(height: minimumHeight)
            .background(Palette.surface, in: .rect(cornerRadius: Metrics.rowRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.rowRadius)
                    .strokeBorder(Palette.well, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}
