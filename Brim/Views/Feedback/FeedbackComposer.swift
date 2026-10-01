import BrimUI
import SwiftUI

struct FeedbackComposer: View {
    @Environment(FeedbackModel.self) private var feedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusesTitle: Bool
    @State private var showsSteps = false
    @State private var showsPreview = false

    var body: some View {
        @Bindable var feedback = feedback
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Feedback type", selection: $feedback.draft.kind) {
                        ForEach(FeedbackKind.allCases, id: \.self) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Title").font(.headline)
                        TextField("A short summary", text: $feedback.draft.title)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .focused($focusesTitle)
                            .accessibilityLabel("Report title")
                        if feedback.draft.title.count > 100 {
                            Text("\(feedback.draft.title.count) / 120 characters")
                                .font(.caption)
                                .foregroundStyle(
                                    feedback.draft.title.count > 120 ? Palette.caution : Palette.inkSecondary
                                )
                        }
                    }
                    FeedbackTextInput(
                        title: "Description", prompt: feedback.draft.kind.descriptionPrompt,
                        text: $feedback.draft.details, minimumHeight: 140, limit: 6000
                    )
                    if feedback.draft.kind == .bug {
                        DisclosureGroup("Steps and expected result (optional)", isExpanded: $showsSteps) {
                            VStack(spacing: 16) {
                                FeedbackTextInput(
                                    title: "Steps to reproduce", prompt: "1. Open Brim…\n2. …",
                                    text: $feedback.draft.reproduction, minimumHeight: 90, limit: 4000
                                )
                                FeedbackTextInput(
                                    title: "Expected result", prompt: "What should have happened?",
                                    text: $feedback.draft.expected, minimumHeight: 60, limit: 2000
                                )
                            }
                            .padding(.top, 12)
                        }
                        .font(.callout)
                    }
                    FeedbackEnvironmentControl()
                    DisclosureGroup("Preview your report", isExpanded: $showsPreview) {
                        Text(feedback.report.copyText)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Palette.surface, in: .rect(cornerRadius: Metrics.rowRadius))
                            .padding(.top, 10)
                    }
                    .font(.callout)
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.bottom, Metrics.pagePadding)
                .disabled(feedback.isSending)
            }
            FeedbackComposerFooter()
        }
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: showsSteps)
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: showsPreview)
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: feedback.draft.kind)
        .onAppear { focusesTitle = true }
    }
}
