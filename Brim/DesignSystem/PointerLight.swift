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
    /// A third of a full light, everywhere: brighter read as the page
    /// lighting up rather than the card answering.
    private let strength = 0.3
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

        /// Cards stayed lit and raised after the pointer left, and the window
        /// looked frozen. AppKit reports leaving only an area it saw the
        /// pointer enter, and an area rebuilt under the pointer (the card's
        /// own lift moves this view; so does scrolling) never saw that. So
        /// the area is rebuilt with `assumeInside` when the pointer is in it,
        /// and every pointer move in the window is checked against this view
        /// too, which lets the card go whatever AppKit reports.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            let point = pointer()
            var options: NSTrackingArea.Options = [
                .mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect
            ]
            if let point, visibleRect.contains(point) {
                options.insert(.assumeInside)
            }
            addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self))
            follow(point)
        }

        override func mouseEntered(with event: NSEvent) {
            follow(convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            follow(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with _: NSEvent) {
            leave()
        }

        /// The pointer in this view's coordinates, while the window is key.
        private func pointer() -> CGPoint? {
            guard let window, window.isKeyWindow else { return nil }
            return convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }

        private func follow(_ point: CGPoint?) {
            guard let point, visibleRect.contains(point) else {
                leave()
                return
            }
            isInside = true
            onChange?(point)
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
            guard let window else {
                PointerWatch.forget(self)
                isInside = false
                onChange?(nil)
                return
            }
            // Pointer moves over empty canvas reach the watch only if the
            // window asks for them.
            window.acceptsMouseMovedEvents = true
            PointerWatch.watch(self)
            // A window losing focus stops its tracking areas without an exit.
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.leave() }
            }
        }

        /// Called by `PointerWatch` for every pointer move, in this window or
        /// outside the app, while this view thinks the pointer is inside.
        fileprivate func recheck(_ event: NSEvent) {
            guard isInside else { return }
            if event.window !== window || event.type == .scrollWheel {
                follow(pointer())
            } else {
                follow(convert(event.locationInWindow, from: nil))
            }
        }
    }
}

/// One watch over the pointer for every tracking view: a local monitor for
/// moves and scrolls in Brim's windows and a global one for moves outside
/// them, which is where the pointer goes when it leaves the window and no
/// exit arrives. Only views that think the pointer is inside do anything.
@MainActor
private enum PointerWatch {
    private static let views = NSHashTable<PointerTracking.TrackingView>.weakObjects()
    private static var monitors: [Any] = []

    static func watch(_ view: PointerTracking.TrackingView) {
        views.add(view)
        guard monitors.isEmpty else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .scrollWheel]
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { event in
            MainActor.assumeIsolated { recheck(event) }
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { event in
            MainActor.assumeIsolated { recheck(event) }
        }) {
            monitors.append(global)
        }
    }

    static func forget(_ view: PointerTracking.TrackingView) {
        views.remove(view)
    }

    private static func recheck(_ event: NSEvent) {
        for view in views.allObjects {
            view.recheck(event)
        }
    }
}
