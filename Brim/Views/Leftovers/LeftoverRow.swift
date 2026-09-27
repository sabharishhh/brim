import BrimCore
import BrimUI
import SwiftUI

extension LeftoverDomain {
    /// The symbol beside a location's word (plan §9.1).
    var symbolName: String {
        switch self {
        case .cache: "arrow.triangle.2.circlepath"
        case .applicationSupport: "folder"
        case .preferences: "slider.horizontal.3"
        case .logs: "doc.text"
        case .savedState: "macwindow"
        case .webData: "globe"
        case .container, .groupContainer: "shippingbox"
        case .launchAgent: "clock.arrow.circlepath"
        case .darwinPerUser: "clock"
        case .other: "questionmark.folder"
        }
    }
}

/// One owner in a stack: tick, icon, name, where it lives, confidence,
/// size. A fixed height, so a long list is measured by arithmetic.
struct LeftoverRow: View {
    let group: LeftoverGroup
    let isPicked: Bool
    let isInspected: Bool
    let isKept: Bool
    let isNew: Bool
    /// Size against the largest row in the same card.
    let sizeFraction: Double
    let pick: () -> Void
    let inspect: () -> Void
    let keep: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Select \(group.displayName)", isOn: Binding(get: { isPicked }, set: { _ in pick() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!canPick)
                .help(pickHelp)

            BrimIcon(source: group.ownerIcon, badge: badge, isNew: isNew)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                facts
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(isInspected ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel(accessibilitySentence)
            .accessibilityAction { inspect() }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                Button(action: keep) {
                    Image(systemName: isKept ? "pin.slash" : "pin")
                }
                .help(isKept ? "Stop keeping" : "Keep")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(group.items.map(\.url))
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("Reveal in Finder")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.inkSecondary)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)

            EvidenceMeter(tier: LeftoverGrouper.confidence(group), showsLabel: false)
                .frame(width: 20)

            VStack(alignment: .trailing, spacing: 5) {
                Text(ByteText.short(group.totalBytes))
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
                SizeBar(fraction: sizeFraction)
            }
            .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.rowHeight)
        .background(highlight, in: .rect(cornerRadius: Metrics.rowRadius, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(perform: inspect)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
    }

    private var canPick: Bool {
        group.isFullyActionable && !isKept
    }

    private var pickHelp: String {
        if isKept {
            return "Kept"
        }
        if !group.isFullyActionable {
            return group.sharedObstacle.flatMap(RemovalCapability.explanation) ?? "Needs an administrator"
        }
        return isPicked ? "Remove from Tray" : "Add to Tray"
    }

    private var badge: IconBadge? {
        if isKept {
            return .kept
        }
        if !group.isFullyActionable {
            return .helper
        }
        if group.meaningfulBytes == 0 {
            return .regenerates
        }
        return nil
    }

    private var highlight: AnyShapeStyle {
        if isInspected {
            return AnyShapeStyle(.tint.opacity(0.10))
        }
        return AnyShapeStyle(isHovering ? Palette.well : Color.clear)
    }

    /// "3 places · Cache · Settings", each word with its symbol.
    private var facts: some View {
        HStack(spacing: 6) {
            Text(group.items.count == 1 ? "1 place" : "\(group.items.count) places")
            ForEach(group.domains.prefix(2), id: \.self) { domain in
                Label(domain.title, systemImage: domain.symbolName)
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
            }
            if group.domains.count > 2 {
                Text("+\(group.domains.count - 2)")
            }
        }
        .font(.brimFacts)
        .foregroundStyle(Palette.inkSecondary)
    }

    private var accessibilitySentence: String {
        let places = group.items.count == 1 ? "1 place" : "\(group.items.count) places"
        let tier = LeftoverGrouper.confidence(group)
        let confidence = tier == .A ? "sure" : tier == .B ? "likely" : "a guess"
        return "\(group.displayName), \(places), \(ByteText.short(group.totalBytes)), confidence \(confidence)"
            + (isKept ? ", kept" : "")
    }
}

/// The part of a card behind one row: rounded at the top of a card, at
/// the bottom, at both for a card of one, and square in between.
struct CardSlice: View {
    enum Position { case only, first, middle, last }

    let position: Position

    var body: some View {
        let radius = Metrics.cardRadius
        let top: CGFloat = position == .only || position == .first ? radius : 0
        let bottom: CGFloat = position == .only || position == .last ? radius : 0
        UnevenRoundedRectangle(
            topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
            topTrailingRadius: top, style: .continuous
        )
        .fill(Palette.surface)
        .padding(.horizontal, 16)
        .padding(.top, top > 0 ? 4 : 0)
        .padding(.bottom, bottom > 0 ? 4 : 0)
    }

    static func position(of index: Int, in count: Int) -> Position {
        if count == 1 {
            return .only
        }
        if index == 0 {
            return .first
        }
        return index == count - 1 ? .last : .middle
    }
}
