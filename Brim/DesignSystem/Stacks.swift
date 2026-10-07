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
