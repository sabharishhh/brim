import BrimUI
import SwiftUI

/// A small mark on an icon's corner. It adds to the icon and never
/// replaces it, so the eye still finds the app first.
enum IconBadge: String, CaseIterable {
    case removed
    case shared
    case helper
    case kept
    case regenerates
    case job

    var symbolName: String {
        switch self {
        case .removed: "xmark"
        case .shared: "shield.fill"
        case .helper: "lock.fill"
        case .kept: "pin.fill"
        case .regenerates: "arrow.triangle.2.circlepath"
        case .job: "gearshape.fill"
        }
    }
}

/// The one icon view for every row, drawn from `IconResolver`'s answer.
struct BrimIcon: View {
    let source: IconSource
    var size: CGFloat = Metrics.rowIcon
    var badge: IconBadge?
    /// New since the last visit: a dot in the accent colour.
    var isNew = false

    var body: some View {
        face
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let mark = badge ?? (isRemembered ? .removed : nil) {
                    BadgeMark(badge: mark, size: size * 0.44)
                        .offset(x: size * 0.1, y: size * 0.1)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isNew {
                    Circle()
                        .fill(.tint)
                        .stroke(Palette.canvas, lineWidth: 1.5)
                        .frame(width: size * 0.28, height: size * 0.28)
                        .offset(x: size * 0.08, y: -size * 0.08)
                        .transition(.opacity)
                }
            }
            // The name is beside it everywhere this is used, and the row's
            // own label names the kind.
            .accessibilityHidden(true)
    }

    private var isRemembered: Bool {
        if case .remembered = source {
            return true
        }
        return false
    }

    @ViewBuilder private var face: some View {
        switch source {
        case let .bundle(url), let .finder(url):
            Image(nsImage: AppIcon.image(for: url, size: size))
                .resizable()
        case let .remembered(bundleID):
            if let image = RememberedIcon.image(for: bundleID) {
                // Grey, because the app it stands for is gone.
                Image(nsImage: image)
                    .resizable()
                    .saturation(0)
                    .opacity(0.75)
            } else {
                MonogramTile(monogram: Monogram(name: bundleID), size: size)
            }
        case let .symbol(kind):
            SymbolTile(kind: kind, size: size)
        case let .monogram(monogram):
            MonogramTile(monogram: monogram, size: size)
        }
    }
}

/// Letters on a muted colour, shaped like an app icon so it sits in a
/// column of real ones without looking like a placeholder.
struct MonogramTile: View {
    let monogram: Monogram
    let size: CGFloat

    /// Two letters sit a little smaller so they fit the same square.
    private var letterScale: CGFloat {
        monogram.letters.count > 1 ? 0.38 : 0.46
    }

    var body: some View {
        let hue = Palette.hue(monogram.hue)
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(hue.gradient)
            .overlay {
                Text(monogram.letters)
                    .font(.system(size: size * letterScale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(size * 0.06)
    }
}

/// A registration's symbol in a tinted square. Each kind keeps one hue,
/// so a column of launch agents is one colour and a login item stands out.
struct SymbolTile: View {
    let kind: ItemKind
    let size: CGFloat

    var body: some View {
        let hue = Palette.hue(ItemKind.allCases.firstIndex(of: kind) ?? 0)
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(hue.opacity(0.6))
            .overlay {
                Image(systemName: kind.symbolName)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(Palette.snow)
            }
            .overlay {
                if kind == .commandLink {
                    // A dead link: the link symbol, struck through.
                    Rectangle()
                        .fill(hue)
                        .frame(width: size * 0.6, height: 1.5)
                        .rotationEffect(.degrees(-45))
                }
            }
            .padding(size * 0.06)
    }
}

struct BadgeMark: View {
    let badge: IconBadge
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Palette.canvas)
            .overlay {
                Image(systemName: badge.symbolName)
                    .font(.system(size: size * 0.52, weight: .bold))
                    .foregroundStyle(badge == .shared || badge == .helper ? Palette.caution : Palette.inkSecondary)
            }
            .frame(width: size, height: size)
    }
}
