import AppKit
import SwiftUI

/// Brim's colours.
///
/// The chrome stays close to monochrome so the colour on screen comes from
/// the person's own app icons. Paper rather than white, ink rather than
/// black, and one accent that means "selected, working, or proven". The
/// accent itself is the `AccentColor` asset, so a person who picked their
/// own accent in System Settings gets theirs instead.
enum Palette {
    static let paper = Color(light: 0xF7F6F2, dark: 0x1B1A18)
    static let surface = Color(light: 0xFFFFFF, dark: 0x242320)
    static let ink = Color(light: 0x1C1B19, dark: 0xF2F0EA)
    static let inkSecondary = Color(light: 0x1C1B19, dark: 0xF2F0EA, alpha: 0.62)
    static let inkTertiary = Color(light: 0x1C1B19, dark: 0xF2F0EA, alpha: 0.38)
    static let hairline = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.09)
    /// Fills behind bars, meters and symbols.
    static let well = Color(light: 0x1C1B19, dark: 0xF2F0EA, lightAlpha: 0.06, darkAlpha: 0.10)
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
    static let rowRadius: CGFloat = 12
    static let cardPadding: CGFloat = 8
    static let pagePadding: CGFloat = 24

    static let rowIcon: CGFloat = 32
    static let compactRowIcon: CGFloat = 24
    static let rowHeight: CGFloat = 52
    static let compactRowHeight: CGFloat = 34
    /// A card shows this many rows, then "Show all". Seven is about what
    /// can be compared at a glance without scrolling inside a group.
    static let rowsBeforeShowAll = 7
}

/// Type styles. SF Pro everywhere; the serif appears only in the Home
/// headline and the Journal's day headers, where Brim is speaking rather
/// than listing.
extension Font {
    static let brimHeadline = Font.system(size: 30, weight: .regular, design: .serif)
    static let brimDayHeader = Font.system(.title3, design: .serif)
    static let brimPageTitle = Font.system(.title2, weight: .semibold)
    static let brimGroupTitle = Font.system(.headline)
    static let brimRowTitle = Font.system(.body, weight: .medium)
    static let brimFacts = Font.system(.subheadline)
    static let brimFigure = Font.system(size: 28, weight: .semibold).monospacedDigit()
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
