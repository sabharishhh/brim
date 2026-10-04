import BrimUI
import SwiftUI

struct FeedbackMenuItem: View {
    @Environment(FeedbackModel.self) private var feedback
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Send Feedback…") {
            feedback.editAgain()
            openWindow(id: FeedbackWindow.windowID)
        }
    }
}
