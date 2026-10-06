import BrimUI
import SwiftUI

/// Brim's character, where the person meets it: Welcome and About.
///
/// It leans a little toward the pointer, at most 3 degrees and 2 points,
/// within its own region, so it reads as a small physical object rather
/// than a picture. Nothing else moves with it: text and buttons sit
/// outside the transform. There is no idle motion, and under Reduce
/// Motion, or while the window is inactive, it simply stays still. The
/// sidebar's small icon never moves.
struct CharacterArtwork: View {
    let size: CGFloat

    /// Where the pointer is across the region, from -1 to 1 on each axis.
    @State private var lean: CGPoint = .zero
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.Environment(\.appearsActive) private var appearsActive

    private static let maximumTilt = 3.0
    private static let maximumShift: CGFloat = 2

    /// The region that responds: a margin round the artwork, never more
    /// than 160 points.
    private var region: CGFloat {
        min(size + 40, 160)
    }

    var body: some View {
        BrimIcon(source: .bundle(Bundle.main.bundleURL), size: size)
            .rotation3DEffect(.degrees(-lean.y * Self.maximumTilt), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(lean.x * Self.maximumTilt), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .offset(x: lean.x * Self.maximumShift, y: lean.y * Self.maximumShift)
            .frame(width: region, height: region)
            .contentShape(.rect)
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard !reduceMotion, appearsActive else { return }
                switch phase {
                case let .active(location):
                    withAnimation(Motion.pointerLight) { lean = Self.normalized(location, in: region) }
                case .ended:
                    withAnimation(Motion.release) { lean = .zero }
                }
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced {
                    lean = .zero
                }
            }
            .onChange(of: appearsActive) { _, active in
                if !active {
                    lean = .zero
                }
            }
            .accessibilityHidden(true)
    }

    static func normalized(_ location: CGPoint, in region: CGFloat) -> CGPoint {
        func axis(_ value: CGFloat) -> CGFloat {
            min(max((value / region - 0.5) * 2, -1), 1)
        }
        return CGPoint(x: axis(location.x), y: axis(location.y))
    }
}
