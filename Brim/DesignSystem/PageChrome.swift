import SwiftUI

// MARK: - Page title

extension View {
    /// The page's name, alone, in the toolbar row and aligned with the page's
    /// content. `shown: false` keeps the window title but draws nothing, where
    /// the toolbar already says it.
    @ViewBuilder
    func pageTitle(_ title: String, centredWidth: CGFloat? = nil, shown: Bool = true) -> some View {
        if shown {
            navigationTitle(title)
                .modifier(PageTitleBar(title: title, centredWidth: centredWidth))
        } else {
            navigationTitle(title)
        }
    }
}

private struct PageTitleBar: ViewModifier {
    let title: String
    let centredWidth: CGFloat?
    /// Dimmed in a window that is not in front, as macOS's own titles are.
    @SwiftUI.Environment(\.controlActiveState) private var activeState
    /// The toolbar row's height, used when the page's frame starts below it.
    private static let toolbarHeight: CGFloat = 52

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            GeometryReader { proxy in
                let inset = proxy.safeAreaInsets.top
                let height = inset > 0 ? inset : Self.toolbarHeight
                HStack(spacing: 0) {
                    if centredWidth != nil {
                        Spacer(minLength: 0)
                    }
                    Text(title)
                        .font(.brimToolbarTitle)
                        .foregroundStyle(activeState == .inactive ? Palette.inkSecondary : Palette.ink)
                        .lineLimit(1)
                        .frame(maxWidth: centredWidth ?? .infinity, alignment: .leading)
                        .padding(.horizontal, Metrics.pagePadding)
                        .accessibilityAddTraits(.isHeader)
                    if centredWidth != nil {
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: height)
                .offset(y: inset > 0 ? -inset : -height)
                // Decoration over the toolbar's row: the window is still
                // dragged by it and its buttons still take their clicks.
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Search

/// The search field at the top of a list: a flat capsule, not glass, because
/// it sits in the content. Escape clears it and Command-F focuses it.
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
        .background(Color.white.opacity(0.07), in: .capsule)
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(isFocused ? 0.35 : 0), lineWidth: 1)
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
