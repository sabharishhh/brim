import BrimUI
import SwiftUI

struct FeedbackResultView: View {
    @Environment(FeedbackModel.self) private var feedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: feedback.receipt == nil ? "arrow.up.right.square" : "checkmark.seal.fill")
                .font(.system(size: 52, weight: .light))
                // Green only once GitHub confirms the report; the handoff
                // before that is a next step, in the accent.
                .foregroundStyle(feedback.receipt == nil ? Color.accentColor : Palette.success)
                .symbolEffect(.bounce, options: .nonRepeating, isActive: !reduceMotion && feedback.receipt != nil)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(feedback.receipt == nil ? "Ready on GitHub" : "Thanks for helping Brim")
                    .font(.brimHeadline)
                Text(feedback.receipt == nil
                    ? "Create the issue in your browser to finish."
                    : "Follow your report on GitHub.")
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let receipt = feedback.receipt {
                Link(destination: receipt.url) {
                    Label("View report #\(receipt.number)", systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            HStack(spacing: 12) {
                Button(feedback.receipt == nil ? "Back to draft" : "Write another") { feedback.editAgain() }
                Button("Done") { dismissWindow(id: FeedbackWindow.windowID) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            Spacer()
            Text("Public report on GitHub")
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
