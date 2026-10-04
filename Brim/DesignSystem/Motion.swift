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
    /// A page chosen with the pointer replaces the last one by fading,
    /// keeping the shell fixed. Chosen from the keyboard, it is immediate.
    static let navigate = Animation.easeOut(duration: 0.18)
    /// A toast or tray settling into place, and leaving it.
    static let toastArrive = Animation.easeOut(duration: 0.18)
    static let trayArrive = Animation.spring(duration: 0.22, bounce: 0)
    static let leave = Animation.easeOut(duration: 0.12)
    /// The tray, a drop, the proof. One of these per flow.
    static let emphasis = Animation.spring(response: 0.45, dampingFraction: 0.82)
    /// Numbers and bars.
    static let data = Animation.smooth(duration: 0.5)
    /// The inspector's content when the selection changes. Short, and a
    /// crossfade only: arrowing through a list must not make it swim.
    static let inspector = Animation.easeOut(duration: 0.12)
    /// What every animation becomes under Reduce Motion.
    static let reduced = Animation.easeInOut(duration: 0.2)

    static let acknowledge = Animation.easeOut(duration: 0.1)
    static let lightExit = Animation.easeOut(duration: 0.12)
    static let pointerLight = Animation.spring(duration: 0.18, bounce: 0)
    static let release = Animation.spring(duration: 0.18, bounce: 0)
    static let openEvidence = Animation.spring(duration: 0.22, bounce: 0)
    /// One verified mark finishing in place.
    static let resolve = Animation.easeOut(duration: 0.24)
    static let refreshEnter = Animation.smooth(duration: 0.25)
    static let refreshSettle = Animation.smooth(duration: 0.18)

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

    /// A floating notice or the tray: arrives from 4 points below in the
    /// given time and leaves by fading in 120 ms. Under Reduce Motion it
    /// only fades.
    static func floating(arrival: Animation, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(Motion.reduced) }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 4)).animation(arrival),
            removal: .opacity.animation(Motion.leave)
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
