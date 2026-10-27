import SwiftUI

/// Native cursor regions follow the view's lifetime and restore the enclosing
/// region automatically when a control disappears or becomes disabled.
private struct ActionPointer: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.pointerStyle(isEnabled ? .link : .default)
    }
}

/// Keeps each system button's behavior and appearance, adding a cursor only
/// over the button itself even when the style is applied to a whole container.
struct PointerButtonStyle<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    let base: Base

    init(_ base: Base) {
        self.base = base
    }

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(base)
            .actionPointer()
    }
}

extension View {
    func actionPointer() -> some View {
        modifier(ActionPointer())
    }

    func selectableText() -> some View {
        textSelection(.enabled)
            .pointerStyle(.horizontalText)
    }
}
