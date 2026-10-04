import AppKit
import SwiftUI

/// Brim's colours.
///
/// Surfaces come from the asset catalog (`Canvas`, `Surface`), each with
/// dark and increased contrast variants, and text and fills are the
/// system's own semantic colours, so Increase Contrast, Reduce
/// Transparency and desktop tinting all reach them the way they reach any
/// Mac app. The colour on screen comes from the person's app icons and one
/// accent, the `AccentColor` asset, which follows their System Settings
/// choice.
///
/// Regions are told apart by shade, never by a line: the canvas, cards one
/// step up from it, and the system sidebar.
enum Palette {
    /// The window's one background, under the toolbar, every page and
    /// every side pane alike.
    static let canvas = Color("Canvas")
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
    /// Staying, needs a look.
    static let caution = Color.orange
    /// Permanent deletion, and nothing else.
    static let destructive = Color.red

    /// Eight muted hues for monograms and symbol tiles, in the order
    /// `Monogram.hue` indexes them. Spaced around the wheel and kept away
    /// from red, which in this product means something.
    static let hues: [Color] = [
        Color(light: 0x6F9A8B, dark: 0x86B3A3), // sage
        Color(light: 0x5E8FA8, dark: 0x78A9C2), // steel
        Color(light: 0x7C83B8, dark: 0x979DD0), // periwinkle
        Color(light: 0x9A7BB0, dark: 0xB396C8), // lavender
        Color(light: 0xB07A93, dark: 0xC894AC), // mauve
        Color(light: 0xC08A64, dark: 0xD6A17D), // clay
        Color(light: 0xB59A55, dark: 0xCBB16E), // ochre
        Color(light: 0x8C9A5B, dark: 0xA4B274) // olive
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

    /// The smallest window the three columns fit in: sidebar 200, list
    /// 440, review pane 440, dividers. Below this the layout overlaps.
    static let windowMinWidth: CGFloat = 1100
    static let windowMinHeight: CGFloat = 640
    /// A list column never narrower than this.
    static let listMinWidth: CGFloat = 440
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
