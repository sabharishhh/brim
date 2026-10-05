import BrimUI
import SwiftUI

struct FeedbackComposer: View {
    @Environment(FeedbackModel.self) private var feedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusesTitle: Bool
    @State private var showsSteps = false

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
                        HStack {
                            Text("Title").font(.headline)
                            Spacer()
                            FeedbackCharacterCount(count: feedback.draft.title.count, limit: FeedbackDraft.Limit.title)
                        }
                        TextField(feedback.draft.kind.titlePrompt, text: $feedback.draft.title)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .focused($focusesTitle)
                            .accessibilityLabel("Report title")
                            .onChange(of: feedback.draft.title) { _, new in
                                if new.count > FeedbackDraft.Limit.title {
                                    feedback.draft.title = String(new.prefix(FeedbackDraft.Limit.title))
                                }
                            }
                    }
                    FeedbackTextInput(
                        title: "Description", prompt: feedback.draft.kind.descriptionPrompt,
                        text: $feedback.draft.details, minimumHeight: 140, limit: FeedbackDraft.Limit.details,
                        dictates: true
                    )
                    if feedback.draft.kind == .bug {
                        // The whole line opens it. A disclosure group's own
                        // label answers only on its chevron.
                        DisclosureGroup(isExpanded: $showsSteps) {
                            VStack(spacing: 16) {
                                FeedbackTextInput(
                                    title: "Steps to reproduce", prompt: "1. Open Brim…\n2. …",
                                    text: $feedback.draft.reproduction, minimumHeight: 90,
                                    limit: FeedbackDraft.Limit.reproduction
                                )
                                FeedbackTextInput(
                                    title: "Expected result", prompt: "What should have happened?",
                                    text: $feedback.draft.expected, minimumHeight: 60,
                                    limit: FeedbackDraft.Limit.expected
                                )
                            }
                            .padding(.top, 12)
                        } label: {
                            Button {
                                showsSteps.toggle()
                            } label: {
                                Text("Steps and expected result (optional)")
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.callout)
                    }
                    FeedbackEnvironmentControl()
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.bottom, Metrics.pagePadding)
                .disabled(feedback.isSending)
            }
            FeedbackComposerFooter()
        }
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: showsSteps)
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: feedback.draft.kind)
        .onAppear { focusesTitle = true }
    }
}
