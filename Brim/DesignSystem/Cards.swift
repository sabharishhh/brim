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
                // Wraps rather than squeezing, so a narrow pane gets two
                // tidy lines instead of words broken over four.
                FlowLayout(spacing: 14, lineSpacing: 6) {
                    ForEach(segments.filter { $0.value > 0 }) { segment in
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
    /// Showing the last scan's figures while a new scan runs: they go grey
    /// until the new ones arrive. The card still opens its page.
    var isRefreshing = false
    @ViewBuilder var detail: Detail
    let action: () -> Void

    @State private var isHovering = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .foregroundStyle(Palette.inkSecondary)
                    Text(title)
                        .font(.brimGroupTitle)
                        .foregroundStyle(Palette.ink)
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
                    Group {
                        Text(figure)
                            .font(.brimFigure)
                            .foregroundStyle(Palette.ink)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                        HStack(spacing: 6) {
                            StatusDot(status: status)
                            Text(phrase)
                                .font(.brimFacts)
                                .foregroundStyle(Palette.inkSecondary)
                                .lineLimit(1)
                        }
                    }
                    .refreshAppearance(isRefreshing)
                    .transition(.opacity)
                }
                if status != .checking {
                    detail
                        .refreshAppearance(isRefreshing)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            // Keep the card's full height, including its padding, when
            // its meter legend needs more room than the minimum allows.
            .fixedSize(horizontal: false, vertical: true)
            .animation(reduceMotion ? nil : Motion.standard, value: status == .checking)
            .card()
            .shadow(color: .black.opacity(isHovering ? 0.08 : 0), radius: 12, y: 4)
            .offset(y: isHovering && !reduceMotion ? -2 : 0)
            .animation(nil, value: reduceMotion)
        }
        .buttonStyle(.press)
        .onHover { hovering in
            withAnimation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion)) { isHovering = hovering }
        }
        .accessibilityLabel("\(title), \(figure), \(phrase)")
    }
}

extension StatCard where Detail == EmptyView {
    init(
        title: String, symbol: String, figure: String, status: CardStatus, phrase: String,
        isRefreshing: Bool = false, action: @escaping () -> Void
    ) {
        self.init(
            title: title, symbol: symbol, figure: figure, status: status, phrase: phrase,
            isRefreshing: isRefreshing, detail: { EmptyView() }, action: action
        )
    }
}

/// Lays views out left to right and wraps to a new line when the next one
/// would not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var top = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var left = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: left, y: top), proposal: ProposedViewSize(size))
                left += size.width + spacing
            }
            top += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
