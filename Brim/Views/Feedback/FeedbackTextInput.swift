import AppKit
import SwiftUI

struct FeedbackTextInput: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let minimumHeight: CGFloat
    let limit: Int
    /// Offers macOS Dictation, for the field people would rather talk through.
    var dictates = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Spacer()
                FeedbackCharacterCount(count: text.count, limit: limit)
                if dictates {
                    Button(action: dictate) {
                        Image(systemName: "mic")
                            .frame(width: 22, height: 22)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .help("Dictate")
                    .accessibilityLabel("Dictate \(title.lowercased())")
                }
            }
            ZStack(alignment: .topLeading) {
                // Gone once the field is in use, not only once it has text:
                // Dictation writes provisional text the binding has not
                // received yet, and the prompt sat over it.
                if text.isEmpty, !isFocused {
                    Text(prompt)
                        .foregroundStyle(Palette.inkTertiary)
                        .padding(.horizontal, 17)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .focused($isFocused)
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
        .onChange(of: text) { _, new in
            if new.count > limit {
                text = String(new.prefix(limit))
            }
        }
    }

    /// The same Dictation the Dictation key starts: on device, in the
    /// person's own language, with no permission of Brim's to grant.
    /// The field takes focus first, because Dictation types into whatever
    /// has it.
    private func dictate() {
        isFocused = true
        // The editor becomes first responder on the next pass, and Dictation
        // starts in whatever is first responder when it is asked, so it waits.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }
}

/// How much of a field is used, quiet until it is nearly full.
struct FeedbackCharacterCount: View {
    let count: Int
    let limit: Int

    var body: some View {
        Text("\(count) / \(limit)")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(count >= limit ? Palette.caution
                : count > limit * 9 / 10 ? Palette.inkSecondary : Palette.inkTertiary)
            .accessibilityLabel("\(count) of \(limit) characters")
    }
}
