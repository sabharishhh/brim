import BrimUI
import SwiftUI

struct FeedbackEnvironmentControl: View {
    @Environment(FeedbackModel.self) private var feedback

    var body: some View {
        @Bindable var feedback = feedback
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $feedback.draft.includesEnvironment) {
                Label("Include app and macOS versions", systemImage: "info.circle")
            }
            .toggleStyle(.checkbox)
            Text(feedback.environment.text.replacingOccurrences(of: "\n", with: " · "))
                .font(.callout)
                .foregroundStyle(Palette.inkSecondary)
                .textSelection(.enabled)
            Text("No logs, file paths or list of installed apps are collected.")
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: .rect(cornerRadius: Metrics.rowRadius))
    }
}
