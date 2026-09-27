import SwiftUI

extension View {
    /// A soft light sweeping across placeholder shapes, so a page that is
    /// still loading looks like it is working rather than empty. Runs only
    /// while the placeholder is on screen, and is still under Reduce Motion.
    func shimmer() -> some View {
        modifier(Shimmer())
    }
}

private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion {
                TimelineView(.animation) { context in
                    let period = 1.6
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: period) / period
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Palette.shimmer, .clear], startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.45)
                        .offset(x: proxy.size.width * (1.45 * phase - 0.45))
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        }
    }
}

/// A placeholder bar for text that has not arrived yet.
struct SkeletonBar: View {
    var width: CGFloat
    var height: CGFloat = 9

    var body: some View {
        Capsule()
            .fill(Palette.well)
            .frame(width: width, height: height)
    }
}

/// Rows in the shape of the real ones while a list is first loading, so
/// nothing moves when content arrives.
struct SkeletonRows: View {
    var count = 7
    var showsTick = true

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0 ..< count, id: \.self) { index in
                HStack(spacing: 12) {
                    if showsTick {
                        RoundedRectangle(cornerRadius: 4).fill(Palette.well).frame(width: 14, height: 14)
                    }
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Palette.well)
                        .frame(width: Metrics.rowIcon, height: Metrics.rowIcon)
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBar(width: [150, 120, 170, 110, 140, 160, 125][index % 7])
                        SkeletonBar(width: [90, 110, 80, 100, 70, 95, 85][index % 7], height: 7)
                    }
                    Spacer()
                    SkeletonBar(width: 54)
                }
                .padding(.horizontal, 12)
                .frame(height: Metrics.rowHeight)
            }
        }
        .shimmer()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Checking")
    }
}
