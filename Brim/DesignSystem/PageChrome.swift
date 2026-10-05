import SwiftUI

// MARK: - Page title

extension View {
    /// The page's name, alone, in the toolbar's row.
    ///
    /// Every page used to draw its own title row under the toolbar, which
    /// left the toolbar's row empty and pushed every list down. The system's
    /// toolbar title was tried next, with the page's facts as a subtitle:
    /// two lines squeezed into the row made the name small and crowded, so
    /// the name is drawn here at heading size on one line, and the facts
    /// stay with the lists that own them. The window keeps the name as its
    /// title for the Window menu and Mission Control.
    func pageTitle(_ title: String) -> some View {
        navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Text(title)
                        .font(.brimToolbarTitle)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 4)
                        .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }
}

// MARK: - Search

/// The search field at the top of a list: a glass capsule with the
/// magnifying glass inside it and a clear button once there is text.
///
/// The rounded-border text field it replaces was the one square, sunken
/// control on a window of capsules and glass. Escape clears the search and
/// Command-F reaches it from anywhere on the page.
struct BrimSearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var isFocused: Bool
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isFocused ? Palette.inkSecondary : Palette.inkTertiary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isFocused)
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.inkTertiary)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
                .accessibilityLabel("Clear Search")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .contentShape(.capsule)
        .onTapGesture { isFocused = true }
        .glassEffect(.regular, in: .capsule)
        .overlay {
            Capsule()
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.55 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: isFocused)
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: text.isEmpty)
        .background {
            Button("Find") { isFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }
}
