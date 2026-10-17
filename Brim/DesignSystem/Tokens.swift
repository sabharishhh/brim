import AppKit
import SwiftUI

/// Brim's colours. Dark only: the canvas is the system's window background
/// and cards sit one step up from it, as grouped rows do in System Settings.
/// Text and fills are system semantic colours, so Increase Contrast reaches
/// them. Colour comes from app icons and status, never from an accent, and
/// regions are told apart by shade, never by a line.
enum Palette {
    /// The window's one background, under the toolbar, every page and
    /// every side pane alike.
    static let canvas = Color(nsColor: .windowBackgroundColor)
    /// Cards and floating panels, one step up from the canvas.
    static let surface = Color("Surface")
    static let ink = Color(nsColor: .labelColor)
    static let inkSecondary = Color(nsColor: .secondaryLabelColor)
    /// The faintest text. The system tertiary label is 2.3:1 on the canvas,
    /// under the 4.5:1 text needs; this is 4.6:1 on a card.
    static let inkTertiary = Color(nsColor: .secondaryLabelColor).opacity(0.9)
    /// Fills behind bars, meters, chips and placeholders.
    static let well = Color(nsColor: .tertiarySystemFill)

    /// A row under the pointer. The same everywhere a row can be hovered.
    static let hover = Color(nsColor: .quaternarySystemFill)
    /// A row while the mouse is down on it: one step stronger than hover,
    /// so a click is felt before anything else changes.
    static let pressed = Color(nsColor: .tertiarySystemFill)
    /// The row the inspector is showing, or the highlighted result.
    static let selected = Color.white.opacity(0.1)

    // Brim is monochrome. Measures and selection are shades of white, and
    // colour is left to status: a red system accent made ordinary facts read
    // as errors.

    /// The tint for controls Brim does not draw itself: checkboxes,
    /// switches, the sidebar's selection. Mid grey, so a white checkmark on
    /// it still reads.
    static let tint = Color(white: 0.5)
    /// Off-white for what a measure shows first, icons and selection. Softer
    /// than pure white, but never grey: at 90% it read as grey beside white text.
    static let snow = Color(white: 0.93)
    /// Text and symbols on `snow`, near black rather than black.
    static let onSnow = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255)
    /// The second: what macOS holds, the other part of a pair.
    static let frost = Color(white: 0.6)
    /// A third, where a measure has one.
    static let mist = Color(white: 0.4)

    /// The light that sweeps across loading placeholders.
    static let shimmer = Color.white.opacity(0.06)
    // Status colours from a colour-blind-safe palette, whose hues stay apart under
    // protanopia, deuteranopia and tritanopia and differ in lightness too.
    // Each is checked against the canvas and cards: 4.5:1 or more where it
    // colours text, 3:1 for marks. Every status also has a word or a symbol,
    // and selection and progress never use these.

    /// Done and checked. Bluish green #009E73, lifted 6% toward
    /// white so it reaches 4.5:1 on a card (4.51; 4.19 before).
    static let success = Color(hex: 0x0FA47B)
    /// Staying, needs a look. Orange #E69F00 (6.4:1 on a card).
    static let caution = Color(hex: 0xE69F00)
    /// Permanent deletion, stopped work and errors, as a mark only.
    /// Vermilion #D55E00 (3.7:1 on a card), so never body text:
    /// the words beside it carry the meaning.
    static let destructive = Color(hex: 0xD55E00)
    /// Neutral information. Sky blue #56B4E9 (6.2:1 on a card).
    static let info = Color(hex: 0x56B4E9)
    /// Low Power Mode. Yellow #F0E442, the colour macOS gives the
    /// battery in that mode, and readable on the dark canvas.
    static let lowPower = Color(hex: 0xF0E442)

    /// Greys for monograms and symbol tiles, in the order `Monogram.hue`
    /// indexes them. Neighbouring tiles differ by a shade.
    static let hues: [Color] = [
        Color(white: 0.34),
        Color(white: 0.42),
        Color(white: 0.3),
        Color(white: 0.38),
        Color(white: 0.46),
        Color(white: 0.32),
        Color(white: 0.4),
        Color(white: 0.36)
    ]

    static func hue(_ index: Int) -> Color {
        hues[((index % hues.count) + hues.count) % hues.count]
    }
}

/// Spacing on an 8 point grid, and radii that nest: the window, then cards,
/// then rows, each smaller by the padding between them.
enum Metrics {
    static let grid: CGFloat = 8
    static let cardRadius: CGFloat = 20
    /// Every highlight shape: rows, results, locations.
    static let rowRadius: CGFloat = 10
    static let cardPadding: CGFloat = 8
    static let pagePadding: CGFloat = 24
    /// Space between the cards of a card page (Home, Space, Energy).
    static let cardSpacing: CGFloat = 16
    /// The widest a card page grows, so a full screen window keeps its
    /// cards at a readable width rather than stretching figures apart.
    static let cardPageWidth: CGFloat = 880

    static let rowIcon: CGFloat = 32
    static let compactRowIcon: CGFloat = 24
    static let rowHeight: CGFloat = 52
    static let compactRowHeight: CGFloat = 34

    static func rowIcon(compact: Bool) -> CGFloat {
        compact ? compactRowIcon : rowIcon
    }

    static func rowHeight(compact: Bool) -> CGFloat {
        compact ? compactRowHeight : rowHeight
    }

    /// A card shows this many rows, then "Show all". Seven is about what
    /// can be compared at a glance without scrolling inside a group.
    static let rowsBeforeShowAll = 7

    /// The smallest window. Below the 860 points a list and its pane need side
    /// by side, the pane floats over the list (`AdaptivePanes`).
    static let windowMinWidth: CGFloat = 900
    static let windowMinHeight: CGFloat = 640
    /// A list column never narrower than this.
    static let listMinWidth: CGFloat = 440
    /// The inspector or review beside a list. One width for both, so a review
    /// opening does not re-measure its list at every animation step.
    static let detailWidth: CGFloat = 420
}

/// Type styles. No serif. SF Pro for lists, SF Pro Rounded where Brim speaks
/// rather than lists: headlines, big figures and the Journal's day headers.
extension Font {
    static let brimHeadline = Font.system(size: 26, weight: .semibold, design: .rounded)
    static let brimDayHeader = Font.system(.title3, design: .rounded, weight: .semibold)
    static let brimPageTitle = Font.system(.title2, design: .rounded, weight: .semibold)
    /// A page's name in the toolbar's row: one line, and the largest text
    /// in the window's chrome.
    static let brimToolbarTitle = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let brimGroupTitle = Font.system(.headline)
    static let brimRowTitle = Font.system(.body, weight: .medium)
    static let brimFacts = Font.system(.subheadline)
    static let brimFigure = Font.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
}

/// Brim is dark only, so each status colour is a single colour.
private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
