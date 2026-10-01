import BrimUI
import SwiftUI

struct FeedbackEnvironmentControl: View {
    @Environment(FeedbackModel.self) private var feedback

    var body: some View {
        Label(feedback.environment.text.replacingOccurrences(of: "\n", with: " · "), systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(Palette.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Included automatically with your report")
    }
}
