import BrimCore
import BrimUI
import SwiftUI

/// A dot for a card's state. The only colour on Home that is not an app
/// icon: the accent when all is well, orange when something wants a look.
struct StatusDot: View {
    let status: CardStatus

    var body: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.mini)
        case .clear:
            dot(AnyShapeStyle(.tint))
        case .attention, .partial:
            dot(AnyShapeStyle(Palette.caution))
        case .neutral:
            dot(AnyShapeStyle(Palette.inkTertiary))
        }
    }

    private func dot(_ style: AnyShapeStyle) -> some View {
        Circle().fill(style).frame(width: 7, height: 7)
    }
}

/// One part of a bar: a label, an amount and its colour.
struct MeterSegment: Identifiable {
    let label: String
    let value: Int64
    let color: Color
    var id: String {
        label
    }
}

/// A proportion bar with a legend. Each segment keeps its own number, so
/// figures that mean different things are never added into one.
struct MeterBar: View {
    let segments: [MeterSegment]
    var showsLegend = true

    private var total: Int64 {
        max(1, segments.reduce(0) { $0 + max(0, $1.value) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(segments) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(0, proxy.size.width * Double(max(0, segment.value)) / Double(total) - 2))
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 8)
            .brimAnimation(Motion.data, value: segments.map(\.value))
            if showsLegend {
                HStack(spacing: 14) {
                    ForEach(segments) { segment in
                        HStack(spacing: 5) {
                            Circle().fill(segment.color).frame(width: 7, height: 7)
                            Text(segment.label).foregroundStyle(Palette.inkSecondary)
                            Text(ByteText.short(segment.value)).foregroundStyle(Palette.ink)
                        }
                    }
                }
                .font(.caption)
                .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.map { "\($0.label) \(ByteText.short($0.value))" }.joined(separator: ", "))
    }
}

/// A Home card: a title, one figure, a short phrase with its state, and
/// room for a bar. It opens the page it describes, lifts on hover and
/// presses like every other control.
struct StatCard<Detail: View>: View {
    let title: String
    let symbol: String
    let figure: String
    let status: CardStatus
    let phrase: String
    var morphID: String?
    @ViewBuilder var detail: Detail
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .foregroundStyle(Palette.inkSecondary)
                    Text(title)
                        .font(.brimGroupTitle)
                        .foregroundStyle(Palette.ink)
                        .pageMorph(morphID ?? title)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.inkTertiary)
                }
                if status == .checking {
                    // The shape of the answer, shimmering, rather than a
                    // zero or an ellipsis nobody measured.
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBar(width: 128, height: 24)
                            .padding(.vertical, 4)
                        SkeletonBar(width: 96)
                    }
                    .shimmer()
                    .transition(.opacity)
                    .accessibilityLabel("Checking")
                } else {
                    Text(figure)
                        .font(.brimFigure)
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                        .transition(.opacity)
                    HStack(spacing: 6) {
                        StatusDot(status: status)
                        Text(phrase)
                            .font(.brimFacts)
                            .foregroundStyle(Palette.inkSecondary)
                            .lineLimit(1)
                    }
                    .transition(.opacity)
                }
                Spacer(minLength: 0)
                if status != .checking {
                    detail
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .animation(Motion.standard, value: status == .checking)
            .card()
            .shadow(color: .black.opacity(isHovering ? 0.08 : 0), radius: 12, y: 4)
            .offset(y: isHovering ? -2 : 0)
        }
        .buttonStyle(.press)
        .onHover { hovering in
            withAnimation(Motion.quick) { isHovering = hovering }
        }
        .accessibilityLabel("\(title), \(figure), \(phrase)")
    }
}

extension StatCard where Detail == EmptyView {
    init(
        title: String, symbol: String, figure: String, status: CardStatus, phrase: String,
        morphID: String? = nil, action: @escaping () -> Void
    ) {
        self.init(
            title: title, symbol: symbol, figure: figure, status: status, phrase: phrase,
            morphID: morphID, detail: { EmptyView() }, action: action
        )
    }
}
