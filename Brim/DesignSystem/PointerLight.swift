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
    /// 1 on a card with a few words; less on one dense with figures, where
    /// a bright light would sit on top of the numbers being read.
    var strength: Double = 1
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
                shape.fill(glow).opacity(0.14 * strength)
                shape.strokeBorder(glow, lineWidth: 1).opacity(strength)
            }
        }
    }
}

/// Brim's action buttons are the system's Liquid Glass buttons.
///
/// They were Brim's own capsules for a while, because a bordered button on
/// the Mac has no hover state and Open Journal and Finish Removal sat still
/// while the cards around them responded. Glass buttons answer the pointer
/// and a press themselves, the way the toolbar's do, follow Reduce
/// Transparency and Increase Contrast without anything written here, and
/// keep the toolbar and the page in one material. Prominent ones carry the
/// person's accent.
extension View {
    /// A glass action button, accent tinted when prominent.
    @ViewBuilder
    func capsuleAction(prominent: Bool = false) -> some View {
        if prominent {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.glass)
        }
    }

    /// The pointer light, inside a rounded card of this radius.
    func pointerLight(cornerRadius: CGFloat = Metrics.cardRadius, strength: Double = 1) -> some View {
        modifier(PointerLight(cornerRadius: cornerRadius, strength: strength))
    }
}

/// Reports where the pointer is over this view, or nil when it leaves,
/// through an AppKit tracking area. Every tracking area hears the pointer
/// whatever it is nested in, which SwiftUI's hover does not promise. The view
/// takes no clicks and is invisible to accessibility.
struct PointerTracking: NSViewRepresentable {
    let onChange: (CGPoint?) -> Void

    func makeNSView(context _: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context _: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((CGPoint?) -> Void)?
        /// Whether the pointer was last reported inside.
        private var isInside = false
        private var resignObserver: NSObjectProtocol?

        override var isFlipped: Bool {
            true
        }

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func isAccessibilityElement() -> Bool {
            false
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self
            ))
            // A tracking area replaced while the pointer is inside it never
            // reports the exit. The card's own lift moves this view and
            // rebuilds the area under the pointer, and so does scrolling, so
            // a card stayed lit and raised after the pointer had left, and
            // the window looked frozen. Ask where the pointer is instead.
            syncWithPointer()
        }

        override func mouseEntered(with event: NSEvent) {
            report(event)
        }

        override func mouseMoved(with event: NSEvent) {
            report(event)
        }

        override func mouseExited(with _: NSEvent) {
            leave()
        }

        private func syncWithPointer() {
            guard let window, window.isKeyWindow else {
                leave()
                return
            }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if visibleRect.contains(point) {
                isInside = true
                onChange?(point)
            } else {
                leave()
            }
        }

        private func leave() {
            guard isInside else { return }
            isInside = false
            onChange?(nil)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
                self.resignObserver = nil
            }
            if let window {
                // A window losing focus stops its tracking areas without
                // an exit, which left the card lit behind another window.
                resignObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.leave() }
                }
            }
            if window == nil {
                isInside = false
                onChange?(nil)
            }
        }

        private func report(_ event: NSEvent) {
            isInside = true
            onChange?(convert(event.locationInWindow, from: nil))
        }
    }
}
