import BrimUI
import SwiftUI

struct FeedbackComposerFooter: View {
    @Environment(FeedbackModel.self) private var feedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var confirmsClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let problem = feedback.problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Report not confirmed. \(problem)")
                    .transition(.opacity)
            }
            Text("Reports are public on GitHub.")
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(feedback.report.copyText, forType: .string)
                } label: {
                    Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.opacity)
                }
                .disabled(feedback.draft.isEmpty || feedback.isSending)
                .onChange(of: feedback.draft) { copied = false }
                Button("Clear") { confirmsClear = true }
                    .disabled(feedback.draft.isEmpty || feedback.isSending)
                    .confirmationDialog("Clear your draft?", isPresented: $confirmsClear) {
                        Button("Clear Draft", role: .destructive) { feedback.clearDraft() }
                    } message: {
                        Text("This removes the text saved on this Mac.")
                    }
                Spacer()
                Button {
                    Task { await feedback.submit { NSWorkspace.shared.open($0) } }
                } label: {
                    HStack(spacing: 8) {
                        if feedback.isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: feedback.usesRelay ? "paperplane" : "arrow.up.right")
                        }
                        Text(submitTitle)
                    }
                    .frame(minWidth: 150)
                    .contentTransition(.opacity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(feedback.draft.validationMessage != nil || feedback.isSending)
                .help(feedback.draft.validationMessage ?? "Share this report")
                .accessibilityLabel(submitTitle)
            }
        }
        .padding(Metrics.pagePadding)
        .background(Palette.surface)
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: feedback.isSending)
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: copied)
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: feedback.problem)
    }

    private var submitTitle: String {
        if feedback.isSending {
            return "Sending…"
        }
        return feedback.usesRelay ? "Send feedback" : "Continue on GitHub"
    }
}
