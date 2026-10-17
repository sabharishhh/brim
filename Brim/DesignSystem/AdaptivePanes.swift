import SwiftUI

/// A collection and the pane that inspects one of its items. Side by side
/// when there is room; otherwise the list takes the full width and the pane
/// floats over its trailing edge while it has something to show. The list
/// stays the same view, so it keeps its scroll position and selection.
struct AdaptivePanes<Collection: View, Detail: View>: View {
    /// The pane's width beside the list, and its widest when floating.
    let detailWidth: CGFloat
    /// There is a selection or a review to show. With nothing, the narrow
    /// layout is the list alone.
    let hasDetail: Bool
    /// A review is open. It has its own Close, and Escape is its own.
    let isReviewing: Bool
    /// Closes the floating pane: clears the selection it shows.
    let close: () -> Void
    @ViewBuilder let collection: () -> Collection
    @ViewBuilder let detail: () -> Detail

    @State private var width: CGFloat = .infinity
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isNarrow: Bool {
        width < Metrics.listMinWidth + detailWidth
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // No minimum on the list: the container must take the width it is offered
            // to notice the window has become too narrow. The threshold below keeps the
            // list at least 440 points wide beside the pane.
            HStack(spacing: 0) {
                collection()
                    .frame(maxWidth: .infinity)
                if !isNarrow {
                    detail()
                        .frame(width: detailWidth)
                }
            }
            if isNarrow, hasDetail {
                floating
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .animation(Motion.resolved(Motion.openEvidence, reduceMotion: reduceMotion), value: isNarrow && hasDetail)
    }

    private var floating: some View {
        detail()
            .frame(width: min(detailWidth, max(width - 48, 280)))
            .frame(maxHeight: .infinity)
            .background(Palette.canvas)
            .overlay(alignment: .leading) {
                Rectangle().fill(Palette.well).frame(width: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 18, x: -6)
            .overlay(alignment: .topTrailing) {
                if !isReviewing {
                    RowAction(symbol: "xmark", help: "Close", action: close)
                        .padding(.top, 14)
                        .padding(.trailing, 14)
                }
            }
            .onKeyPress(.escape) {
                guard !isReviewing else { return .ignored }
                close()
                return .handled
            }
    }
}
