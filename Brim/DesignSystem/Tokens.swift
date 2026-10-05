import AppKit
import SwiftUI

/// Brim's colours.
///
/// Brim is dark only (`AppDelegate` sets the appearance at launch). The
/// canvas is the system's own dark window background, and cards sit one
/// step up from it the way grouped rows do in System Settings, so Brim
/// looks like the Mac it runs on. It used to draw its own near-black canvas,
/// `#0F0F11` against the system's `#1E1E1E`, which made every page darker
/// than any app beside it. Text, fills and the group colours are the
/// system's semantic colours, so Increase Contrast and dark mode reach them
/// the way they reach any Mac app. The colour on screen comes from the
/// person's app icons and one accent.
///
/// Regions are told apart by shade, never by a line: the canvas, cards one
/// step up from it, and the system sidebar.
enum Palette {
    /// The window's one background, under the toolbar, every page and
    /// every side pane alike.
    static let canvas = Color(nsColor: .windowBackgroundColor)
    /// Cards and floating panels, one step up from the canvas.
    static let surface = Color("Surface")
    static let ink = Color(nsColor: .labelColor)
    static let inkSecondary = Color(nsColor: .secondaryLabelColor)
    static let inkTertiary = Color(nsColor: .tertiaryLabelColor)
    /// Fills behind bars, meters, chips and placeholders.
    static let well = Color(nsColor: .tertiarySystemFill)

    /// A row under the pointer. The same everywhere a row can be hovered.
    static let hover = Color(nsColor: .quaternarySystemFill)
    /// A row while the mouse is down on it: one step stronger than hover,
    /// so a click is felt before anything else changes.
    static let pressed = Color(nsColor: .tertiarySystemFill)
    /// The row the inspector is showing, or the highlighted result.
    static let selected = Color.accentColor.opacity(0.18)

    /// The light that sweeps across loading placeholders.
    static let shimmer = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.7, darkAlpha: 0.06)
    // Status colours: the Okabe–Ito palette (Okabe and Ito, Color Universal
    // Design; Wong, "Points of view: Color blindness", Nature Methods 2011),
    // chosen because its hues stay apart under protanopia, deuteranopia and
    // tritanopia, where the usual green and red collapse into one. They
    // differ in lightness too, so they survive greyscale. Each is checked
    // against the dark canvas (#1E1E1E) and cards (#2A2A2C): 4.5:1 or more
    // wherever it can colour text, 3:1 or more for marks. Colour is never
    // the only signal; every status also has a word or a symbol.
    //
    // Accent, selection and progress use the person's own system accent
    // (`Color.accentColor`), never one of these.

    /// Done and checked. Okabe–Ito bluish green #009E73, lifted 6% toward
    /// white so it reaches 4.5:1 on a card (4.51; 4.19 before).
    static let success = Color(light: 0x0FA47B, dark: 0x0FA47B)
    /// Staying, needs a look. Okabe–Ito orange #E69F00 (6.4:1 on a card).
    static let caution = Color(light: 0xE69F00, dark: 0xE69F00)
    /// Permanent deletion, stopped work and errors, as a mark only.
    /// Okabe–Ito vermilion #D55E00 (3.7:1 on a card), so never body text:
    /// the words beside it carry the meaning.
    static let destructive = Color(light: 0xD55E00, dark: 0xD55E00)
    /// Neutral information. Okabe–Ito sky blue #56B4E9 (6.2:1 on a card).
    static let info = Color(light: 0x56B4E9, dark: 0x56B4E9)

    /// Eight system colours for monograms and symbol tiles, in the
    /// order `Monogram.hue` indexes them. The system's own, as in System
    /// Settings, so they adapt to Increase Contrast. Kept away from red,
    /// orange and green, which here are status. Meters use the accent.
    static let hues: [Color] = [
        Color(nsColor: .systemTeal),
        Color(nsColor: .systemBlue),
        Color(nsColor: .systemIndigo),
        Color(nsColor: .systemPurple),
        Color(nsColor: .systemPink),
        Color(nsColor: .systemBrown),
        Color(nsColor: .systemCyan),
        Color(nsColor: .systemGray)
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

    /// The smallest window. A list and its pane need 860 points side by
    /// side; narrower than that the pane floats over the list
    /// (`AdaptivePanes`), so every page still works at 900.
    static let windowMinWidth: CGFloat = 900
    static let windowMinHeight: CGFloat = 640
    /// A list column never narrower than this.
    static let listMinWidth: CGFloat = 440
    /// The inspector or review beside a list. One width for both: the
    /// pane used to widen from 360 to 440 when a review opened, and the
    /// review's list re-measured at every step of the animation, which is
    /// the hitch halfway through the swap.
    static let detailWidth: CGFloat = 420
}

/// Type styles. No serif anywhere. SF Pro for everything read in lists,
/// and SF Pro Rounded where Brim speaks rather than lists: the Home
/// headline, the big figures and the Journal's day headers. Rounded is the
/// system's own, so it renders as crisply as the rest, and it is warmer
/// than the default without looking like a web font.
extension Font {
    static let brimHeadline = Font.system(size: 26, weight: .semibold, design: .rounded)
    static let brimDayHeader = Font.system(.title3, design: .rounded, weight: .semibold)
    static let brimPageTitle = Font.system(.title2, design: .rounded, weight: .semibold)
    static let brimGroupTitle = Font.system(.headline)
    static let brimRowTitle = Font.system(.body, weight: .medium)
    static let brimFacts = Font.system(.subheadline)
    static let brimFigure = Font.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
}

private extension Color {
    init(light: UInt32, dark: UInt32, alpha: Double = 1) {
        self.init(light: light, dark: dark, lightAlpha: alpha, darkAlpha: alpha)
    }

    init(light: UInt32, dark: UInt32, lightAlpha: Double, darkAlpha: Double) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
