import BrimCore
import BrimUI
import SwiftUI

// MARK: - Card

extension View {
    /// A card: one step up from the canvas, and no outline. Regions are
    /// told apart by shade, never by a line.
    func card(radius: CGFloat = Metrics.cardRadius) -> some View {
        background(Palette.surface, in: .rect(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Size bar

/// A thin bar scaled within its group, so the biggest item in a card is
/// visible before a single number is read.
struct SizeBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Palette.well)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Palette.inkTertiary)
                        .frame(width: max(3, proxy.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 3)
            .brimAnimation(Motion.data, value: fraction)
            .accessibilityHidden(true)
    }
}

// MARK: - Status chip

/// A word in a capsule for a state the row is in: Kept, Needs the helper,
/// Staying.
struct StatusChip: View {
    enum Tone { case neutral, accent, caution }

    let text: String
    var symbol: String?
    var tone: Tone = .neutral

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let symbol {
                Image(systemName: symbol)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(background, in: .capsule)
    }

    private var foreground: AnyShapeStyle {
        switch tone {
        case .neutral: AnyShapeStyle(Palette.inkSecondary)
        case .accent: AnyShapeStyle(.tint)
        case .caution: AnyShapeStyle(Palette.caution)
        }
    }

    private var background: AnyShapeStyle {
        switch tone {
        case .neutral: AnyShapeStyle(Palette.well)
        case .accent: AnyShapeStyle(.tint.opacity(0.12))
        case .caution: AnyShapeStyle(Palette.caution.opacity(0.12))
        }
    }
}

// MARK: - Row

/// One row of a stack: icon, name, one line of facts, size with its bar,
/// an accessory, and actions that appear on hover.
///
/// A fixed height, so a long stack is measured by arithmetic rather than by
/// asking every row (`CLAUDE.md`, on `ScrollView { VStack }`).
struct StackRow<Accessory: View, Actions: View>: View {
    let icon: IconSource
    var badge: IconBadge?
    var isNew = false
    let title: String
    let facts: String
    var bytes: Int64?
    var sizeFraction: Double?
    var compact = false
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var actions: Actions

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            BrimIcon(
                source: icon, size: compact ? Metrics.compactRowIcon : Metrics.rowIcon,
                badge: badge, isNew: isNew
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                if !compact {
                    Text(facts)
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            actions
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
            accessory
            if let bytes {
                VStack(alignment: .trailing, spacing: 5) {
                    Text(ByteText.short(bytes))
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                    if let sizeFraction, !compact {
                        SizeBar(fraction: sizeFraction)
                    }
                }
                .frame(minWidth: 56, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: compact ? Metrics.compactRowHeight : Metrics.rowHeight)
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySentence)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityActions { actions }
    }

    private var accessibilitySentence: String {
        [title, compact ? nil : facts, bytes.map(ByteText.short)].compactMap(\.self).joined(separator: ", ")
    }
}

extension StackRow where Actions == EmptyView {
    init(
        icon: IconSource, badge: IconBadge? = nil, isNew: Bool = false, title: String, facts: String,
        bytes: Int64? = nil, sizeFraction: Double? = nil, compact: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.init(
            icon: icon, badge: badge, isNew: isNew, title: title, facts: facts, bytes: bytes,
            sizeFraction: sizeFraction, compact: compact, accessory: accessory, actions: { EmptyView() }
        )
    }
}

// MARK: - List spacing

/// Space that belongs to the list's content, after every section. Keeping
/// it outside folding groups preserves the gap when the last group closes.
/// Native macOS lists did not reliably apply the bottom content margin.
struct ListBottomSpacing: View {
    var body: some View {
        Color.clear
            .frame(height: Metrics.pagePadding)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .selectionDisabled()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Stack card

/// A group as a card: a header that says what is inside, up to seven rows,
/// then "Show all" in place.
///
/// The header carries the scent. "Not opened since June · 7 apps · 12.4 GB"
/// tells somebody whether to open the group without opening it.
struct StackCard<Item: Identifiable, Row: View, HeaderAccessory: View>: View {
    let title: String
    let summary: String
    let items: [Item]
    @Binding var showsAll: Bool
    var compact = false
    @ViewBuilder var row: (Item) -> Row
    @ViewBuilder var headerAccessory: HeaderAccessory

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                row(item)
                    .overlay(alignment: .top) {
                        // In an overlay so each item stays one view, which
                        // keeps `ForEach` diffing cheap.
                        if index > 0 {
                            Rectangle()
                                .fill(Palette.well)
                                .frame(height: 1)
                                .padding(.leading, (compact ? Metrics.compactRowIcon : Metrics.rowIcon) + 24)
                        }
                    }
                    .transition(.brimRow(reduceMotion: reduceMotion))
            }
            if items.count > Metrics.rowsBeforeShowAll {
                Button {
                    withAnimation(reduceMotion ? nil : Motion.openEvidence) {
                        showsAll.toggle()
                    }
                } label: {
                    Text(showsAll ? "Show fewer" : "Show all \(items.count)")
                        .font(.brimFacts.weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.press)
            }
        }
        .padding(Metrics.cardPadding)
        .card()
    }

    private var visible: ArraySlice<Item> {
        showsAll ? items[...] : items.prefix(Metrics.rowsBeforeShowAll)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.brimGroupTitle)
                .foregroundStyle(Palette.ink)
            Text(summary)
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkSecondary)
                .contentTransition(.numericText())
            Spacer()
            headerAccessory
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension StackCard where HeaderAccessory == EmptyView {
    init(
        title: String, summary: String, items: [Item], showsAll: Binding<Bool>, compact: Bool = false,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.init(
            title: title, summary: summary, items: items, showsAll: showsAll, compact: compact,
            row: row, headerAccessory: { EmptyView() }
        )
    }
}

// MARK: - Tile

/// A card that opens somewhere: Home's Leftovers, Background and Space.
/// It lifts two points on hover and presses like every other control.
struct Tile: View {
    let title: String
    let figure: String
    let caption: String
    var icons: [IconSource] = []
    let action: () -> Void

    @State private var isHovering = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title)
                        .font(.brimGroupTitle)
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.inkTertiary)
                }
                Text(figure)
                    .font(.brimFigure)
                    .foregroundStyle(Palette.ink)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                HStack(spacing: -6) {
                    ForEach(Array(icons.prefix(4).enumerated()), id: \.offset) { _, source in
                        BrimIcon(source: source, size: 26)
                    }
                    if !icons.isEmpty {
                        Spacer().frame(width: 18)
                    }
                    Text(caption)
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                }
                // Fixed, so a tile with icons and one without line up.
                .frame(height: 26)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            .shadow(color: .black.opacity(isHovering ? 0.08 : 0), radius: 12, y: 4)
            .offset(y: isHovering && !reduceMotion ? -2 : 0)
            .animation(nil, value: reduceMotion)
        }
        .buttonStyle(.press)
        .onHover { hovering in
            withAnimation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion)) { isHovering = hovering }
        }
        .accessibilityLabel("\(title), \(figure), \(caption)")
    }
}
