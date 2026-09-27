import SwiftUI

/// Four timings, five verbs, and nothing moving while the app is idle.
///
/// Motion here explains a change of place or state and does nothing else.
/// Every animation in the product is one of these, so the app has one
/// rhythm rather than forty, and Reduce Motion turns every one of them into
/// a short crossfade in one place instead of forty.
enum Motion {
    /// Hover, press, toggles.
    static let quick = Animation.snappy(duration: 0.2)
    /// Panels, layout, page changes.
    static let standard = Animation.smooth(duration: 0.35)
    /// The tray, a drop, the proof. One of these per flow.
    static let emphasis = Animation.spring(response: 0.45, dampingFraction: 0.82)
    /// Numbers and bars.
    static let data = Animation.smooth(duration: 0.5)
    /// The inspector's content when the selection changes. Short, and a
    /// crossfade only: arrowing through a list must not make it swim.
    static let inspector = Animation.easeInOut(duration: 0.12)
    /// What every animation becomes under Reduce Motion.
    static let reduced = Animation.easeInOut(duration: 0.2)

    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }
}

extension AnyTransition {
    /// Enter: fades in from 6 points below. Exit: fades while shrinking a
    /// little, so a leaving row reads as going away rather than sliding off.
    static func brimRow(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)),
            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
        )
    }

    /// A page arriving. The sidebar order is vertical space: moving down
    /// it drifts content up, and moving up drifts it down.
    static func brimPage(movingDown: Bool, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: movingDown ? 8 : -8)),
            removal: .opacity
        )
    }
}

extension View {
    /// `withAnimation` for a token, honouring Reduce Motion.
    func brimAnimation(_ animation: Animation, value: some Equatable) -> some View {
        modifier(TokenAnimation(animation: animation, value: value))
    }
}

private struct TokenAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(Motion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}

/// The press every custom control shares: down to 0.97 in a tenth of a
/// second and a spring back. System and glass buttons keep their own.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.1) : Motion.quick, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressStyle {
    static var press: PressStyle {
        PressStyle()
    }
}
