import BrimUI
import SwiftUI

struct FeedbackSettingsView: View {
    @Environment(FeedbackModel.self) private var feedback
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.pagePadding) {
                VStack(alignment: .leading, spacing: Metrics.grid) {
                    Text("Help shape Brim")
                        .font(.brimHeadline)
                    Text("Report a problem, suggest an improvement, or share a thought.")
                        .foregroundStyle(Palette.inkSecondary)
                }
                HStack(alignment: .top, spacing: 12) {
                    ForEach(FeedbackKind.allCases, id: \.self) { kind in
                        FeedbackKindCard(kind: kind) {
                            if feedback.draft.isEmpty {
                                feedback.draft.kind = kind
                            }
                            feedback.editAgain()
                            openWindow(id: FeedbackWindow.windowID)
                        }
                    }
                }
                if !feedback.draft.isEmpty {
                    Button {
                        feedback.editAgain()
                        openWindow(id: FeedbackWindow.windowID)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.and.pencil")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Continue your draft").font(.headline)
                                Text(feedback.draft.title.isEmpty ? feedback.draft.kind.title : feedback.draft.title)
                                    .foregroundStyle(Palette.inkSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Palette.inkTertiary)
                        }
                        .padding(16)
                        .background(Palette.surface, in: .rect(cornerRadius: Metrics.rowRadius))
                    }
                    .buttonStyle(.press)
                }
                if !feedback.recent.isEmpty {
                    FeedbackRecentReports(receipts: feedback.recent)
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock").accessibilityHidden(true)
                    Text("Your draft stays on this Mac until you choose to share it.")
                }
                .font(.callout)
                .foregroundStyle(Palette.inkSecondary)
                HStack {
                    Link(destination: FeedbackDelivery.issuesURL) {
                        Label("Browse reports on GitHub", systemImage: "arrow.up.right")
                    }
                    Spacer()
                    Text(feedback.environment.appLabel)
                        .foregroundStyle(Palette.inkTertiary)
                }
                .font(.callout)
            }
            .padding(Metrics.pagePadding)
        }
        .background(Palette.canvas)
    }
}
