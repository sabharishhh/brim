import BrimUI
import SwiftUI

struct FeedbackWindow: View {
    static let windowID = "feedback"
    @Environment(FeedbackModel.self) private var feedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            FeedbackWindowHeader()
            ZStack {
                if feedback.receipt != nil || feedback.openedBrowser {
                    FeedbackResultView()
                        .transition(.opacity.combined(with: reduceMotion ? .identity : .scale(scale: 0.97)))
                } else {
                    FeedbackComposer()
                        .transition(.opacity)
                }
            }
            .animation(Motion.resolved(Motion.page, reduceMotion: reduceMotion), value: feedback.receipt != nil)
            .animation(Motion.resolved(Motion.page, reduceMotion: reduceMotion), value: feedback.openedBrowser)
        }
        .frame(width: 640, height: 680)
        .background(Palette.canvas)
        .containerBackground(Palette.canvas, for: .window)
    }
}
