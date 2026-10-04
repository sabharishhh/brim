import SwiftUI

/// A solid inspection control whose rim responds to the local pointer.
/// Its label, focus ring and hit region stay stationary.
struct InspectionButtonStyle: ButtonStyle {
    var isTrackingSuspended = false

    func makeBody(configuration: Configuration) -> some View {
        InspectionButtonSurface(
            label: configuration.label, isPressed: configuration.isPressed,
            isTrackingSuspended: isTrackingSuspended
        )
    }
}

private struct InspectionButtonSurface<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let isTrackingSuspended: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var pointer = UnitPoint.center
    @State private var size = CGSize.zero

    private let shape = RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)

    private var acceptsHover: Bool {
        isEnabled && activeState == .key && !isTrackingSuspended
    }

    private var showsLight: Bool {
        acceptsHover && isHovering && !reduceMotion && !reduceTransparency && contrast != .increased
    }

    var body: some View {
        label
            .font(.body.weight(.medium))
            .foregroundStyle(isEnabled ? Palette.ink : Palette.inkSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                backing
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .contentShape(shape)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    guard acceptsHover else { return }
                    isHovering = true
                    if !reduceMotion, showsLight, size.width > 0, size.height > 0 {
                        pointer = UnitPoint(
                            x: min(max(location.x / size.width, 0), 1),
                            y: min(max(location.y / size.height, 0), 1)
                        )
                    }
                case .ended:
                    isHovering = false
                }
            }
            .onChange(of: acceptsHover) { clearHover() }
            .onChange(of: reduceMotion) { clearHover() }
            .onChange(of: reduceTransparency) { clearHover() }
            .onChange(of: contrast) { clearHover() }
            .onDisappear { clearHover() }
    }

    private var backing: some View {
        shape
            .fill(isPressed && isEnabled ? Palette.pressed : Palette.surface)
            .overlay {
                shape.strokeBorder(
                    Palette.inkSecondary.opacity(contrast == .increased ? 0.7 : (isHovering ? 0.3 : 0.16)),
                    lineWidth: 1
                )
            }
            .overlay {
                shape.strokeBorder(
                    RadialGradient(
                        colors: [Palette.ink.opacity(0.55), .clear],
                        center: pointer, startRadius: 0, endRadius: max(size.width * 0.35, 1)
                    ),
                    lineWidth: 1
                )
                .overlay {
                    shape.fill(RadialGradient(
                        colors: [.white.opacity(colorScheme == .dark ? 0.10 : 0.06), .clear],
                        center: pointer, startRadius: 0, endRadius: max(size.width * 0.35, 1)
                    ))
                }
                .animation(Motion.pointerLight, value: pointer)
                .opacity(showsLight ? 1 : 0)
                .animation(showsLight ? Motion.acknowledge : Motion.lightExit, value: showsLight)
            }
            .shadow(color: .black.opacity(isEnabled ? 0.08 : 0), radius: isPressed ? 2 : 6, y: isPressed ? 1 : 2)
            .scaleEffect(isPressed && isEnabled && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : (isPressed ? Motion.acknowledge : Motion.release), value: isPressed)
            .animation(nil, value: reduceMotion)
    }

    private func clearHover() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isHovering = false
            pointer = .center
        }
    }
}
