import SwiftUI

/// Shared timing for feedback, continuity and active work.
/// Callers must also gate spatial properties under Reduce Motion;
/// substituting a timing curve does not remove movement.
enum Motion {
    /// Hover, press, toggles.
    static let quick = Animation.snappy(duration: 0.2)
    /// Panels, layout.
    static let standard = Animation.smooth(duration: 0.35)
    /// A change of page: quick enough that the next click never waits.
    static let page = Animation.smooth(duration: 0.28)
    /// The tray, a drop, the proof. One of these per flow.
    static let emphasis = Animation.spring(response: 0.45, dampingFraction: 0.82)
    /// Numbers and bars.
    static let data = Animation.smooth(duration: 0.5)
    /// The inspector's content when the selection changes. Short, and a
    /// crossfade only: arrowing through a list must not make it swim.
    static let inspector = Animation.easeInOut(duration: 0.12)
    /// What every animation becomes under Reduce Motion.
    static let reduced = Animation.easeInOut(duration: 0.2)

    static let acknowledge = Animation.easeOut(duration: 0.1)
    static let lightExit = Animation.easeOut(duration: 0.12)
    static let pointerLight = Animation.spring(duration: 0.18, bounce: 0)
    static let release = Animation.spring(duration: 0.18, bounce: 0)
    static let refreshEnter = Animation.smooth(duration: 0.25)
    static let refreshSettle = Animation.smooth(duration: 0.6)

    static func refresh(_ isRefreshing: Bool, reduceMotion: Bool) -> Animation {
        resolved(isRefreshing ? refreshEnter : refreshSettle, reduceMotion: reduceMotion)
    }

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

    /// A page arriving: it comes into focus, rising a little from the
    /// direction of travel through the sidebar, while the one leaving
    /// softens and fades. Nothing is carried from one page to the next;
    /// a title flying into a card read as a trick rather than a place.
    static func brimPage(movingDown: Bool, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: PageFocus(blur: 6, scale: 0.99, offset: movingDown ? 10 : -10, opacity: 0),
                identity: PageFocus()
            ),
            removal: .modifier(
                active: PageFocus(blur: 4, scale: 1.005, offset: 0, opacity: 0),
                identity: PageFocus()
            )
        )
    }
}

/// One frame of a page coming into or out of focus.
private struct PageFocus: ViewModifier {
    var blur: CGFloat = 0
    var scale: CGFloat = 1
    var offset: CGFloat = 0
    var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .scaleEffect(scale)
            .offset(y: offset)
            .opacity(opacity)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.75 : 1)
            .animation(
                Motion.resolved(
                    configuration.isPressed ? .easeOut(duration: 0.1) : Motion.quick,
                    reduceMotion: reduceMotion
                ),
                value: configuration.isPressed
            )
            .animation(nil, value: reduceMotion)
    }
}

extension ButtonStyle where Self == PressStyle {
    static var press: PressStyle {
        PressStyle()
    }
}
