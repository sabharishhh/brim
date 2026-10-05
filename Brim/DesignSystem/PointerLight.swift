import AppKit
import SwiftUI

/// A soft light along the inside edge of a card, following the pointer.
///
/// The cursor light from the interaction specification, shared rather than
/// owned by one button: about a third of the card's width lit at once, a
/// 1 point rim and a faint fill, fading in over 100 ms and out over 120 ms,
/// following on a zero-bounce spring. A resting pointer leaves nothing
/// moving. It is decoration only: no hit testing, nothing for VoiceOver, and
/// the label, bounds and focus ring never move. An inactive window, a
/// disabled control, Reduce Motion, Reduce Transparency and Increase
/// Contrast all leave it off.
private struct PointerLight: ViewModifier {
    let cornerRadius: CGFloat
    @State private var location: UnitPoint?
    @State private var isLit = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @SwiftUI.Environment(\.colorSchemeContrast) private var contrast
    @SwiftUI.Environment(\.controlActiveState) private var activeState
    @SwiftUI.Environment(\.isEnabled) private var isEnabled

    private var allowed: Bool {
        !reduceMotion && !reduceTransparency && contrast != .increased && activeState != .inactive && isEnabled
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if allowed, let location {
                    light(at: location)
                        .opacity(isLit ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // macOS's own tracking area, not SwiftUI's hover: where hover
            // regions nest, SwiftUI gives the pointer to one of them, and a
            // card tracking itself took it from the buttons on it.
            .overlay {
                PointerTracking { point in
                    track(point.map(HoverPhase.active) ?? .ended)
                }
                .allowsHitTesting(false)
            }
    }

    private func track(_ phase: HoverPhase) {
        guard allowed else {
            isLit = false
            return
        }
        switch phase {
        case let .active(point):
            // Sizes are read from the light's own geometry, so the point is
            // kept in points here and normalised there.
            let next = UnitPoint(x: point.x, y: point.y)
            if location == nil || !isLit {
                location = next
                withAnimation(Motion.acknowledge) { isLit = true }
            } else {
                withAnimation(Motion.pointerLight) { location = next }
            }
        case .ended:
            withAnimation(Motion.lightExit) { isLit = false }
        }
    }

    private func light(at point: UnitPoint) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = UnitPoint(
                x: min(max(point.x / max(size.width, 1), 0), 1),
                y: min(max(point.y / max(size.height, 1), 0), 1)
            )
            let reach = max(size.width, size.height) * 0.35
            let glow = RadialGradient(
                colors: [.white.opacity(0.75), .white.opacity(0)],
                center: center, startRadius: 0, endRadius: reach
            )
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            ZStack {
                shape.fill(glow).opacity(0.14)
                shape.strokeBorder(glow, lineWidth: 1)
            }
        }
    }
}

/// Brim's capsule action button: the shape the app already used, drawn by
/// Brim so it can answer the pointer. A standard bordered button on the Mac
/// has no hover state, and SwiftUI draws it as an AppKit control above
/// anything layered on it, so Open Journal and Finish Removal sat still
/// while the cards around them responded. Hover brightens the fill, a press
/// sinks it slightly, and disabled dims it. Approval buttons keep the
/// system's own button, which the person should recognise unchanged.
struct CapsuleActionStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        CapsuleActionBody(configuration: configuration, prominent: prominent)
    }
}

private struct CapsuleActionBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @State private var isHovering = false
    @SwiftUI.Environment(\.controlSize) private var controlSize
    @SwiftUI.Environment(\.isEnabled) private var isEnabled
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.Environment(\.colorSchemeContrast) private var contrast

    private var metrics: (font: CGFloat, horizontal: CGFloat, vertical: CGFloat) {
        switch controlSize {
        case .mini, .small: (11, 10, 3)
        case .large, .extraLarge: (13, 18, 7)
        default: (13, 13, 4)
        }
    }

    private var fill: AnyShapeStyle {
        let pressed = configuration.isPressed && isEnabled
        let hovered = isHovering && isEnabled
        if prominent {
            let tint = Color.accentColor
            return AnyShapeStyle(pressed ? tint.mix(with: .black, by: 0.15)
                : hovered ? tint.mix(with: .white, by: 0.12) : tint)
        }
        return AnyShapeStyle(Color.white.opacity(pressed ? 0.2 : hovered ? 0.16 : 0.1))
    }

    var body: some View {
        configuration.label
            .font(.system(size: metrics.font))
            .lineLimit(1)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(Palette.ink))
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .background(fill, in: .capsule)
            .overlay {
                if contrast == .increased {
                    Capsule().strokeBorder(Palette.ink.opacity(0.7), lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(.capsule)
            // Inside the button, where the label is drawn: an AppKit view
            // cannot live in or on a button. Cards track through AppKit, so
            // they never compete with this for the pointer.
            .onHover { hovering in
                guard hovering != isHovering else { return }
                withAnimation(Motion.resolved(hovering ? Motion.acknowledge : Motion.lightExit,
                                              reduceMotion: reduceMotion)) { isHovering = hovering }
            }
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.97 : 1)
            .animation(Motion.resolved(configuration.isPressed ? Motion.acknowledge : Motion.release,
                                       reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

extension View {
    /// Brim's capsule action button, answering the pointer.
    func capsuleAction(prominent: Bool = false) -> some View {
        buttonStyle(CapsuleActionStyle(prominent: prominent))
    }

    /// The pointer light, inside a rounded card of this radius.
    func pointerLight(cornerRadius: CGFloat = Metrics.cardRadius) -> some View {
        modifier(PointerLight(cornerRadius: cornerRadius))
    }

}


/// Reports where the pointer is over this view, or nil when it leaves,
/// through an AppKit tracking area. Every tracking area hears the pointer
/// whatever it is nested in, which SwiftUI's hover does not promise. The view
/// takes no clicks and is invisible to accessibility.
struct PointerTracking: NSViewRepresentable {
    let onChange: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((CGPoint?) -> Void)?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func isAccessibilityElement() -> Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) { report(event) }

        override func mouseMoved(with event: NSEvent) { report(event) }

        override func mouseExited(with event: NSEvent) { onChange?(nil) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                onChange?(nil)
            }
        }

        private func report(_ event: NSEvent) {
            onChange?(convert(event.locationInWindow, from: nil))
        }
    }
}

