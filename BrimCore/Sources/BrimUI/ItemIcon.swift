import SwiftUI
import AppKit
import BrimCore

/// One icon rule for every list in the product.
///
/// Three lists were each solving this differently and two of them were
/// giving up. The energy list drew a real icon for anything with a bundle
/// and a grey `gearshape` for everything else, so five different macOS
/// services shared one glyph and were indistinguishable at a glance. The
/// leftovers list drew nothing at all. A row with no icon and a row with the
/// same icon as four others are the same failure: the eye cannot separate
/// them, so the list has to be read word by word.
///
/// The rule, in order:
///
/// 1. A real bundle gets its real icon, from `NSWorkspace`, which is the
///    only correct way to get one.
/// 2. Anything else gets a glyph for what it *is*, which Brim knows:
///    a folder, a file, a macOS service, a command line tool, a helper.
/// 3. The glyph sits on a colour derived from the item's own name, so two
///    services are two different colours and stay that colour every time
///    the list is drawn. Derived rather than random: a colour that changed
///    between refreshes would be worse than no colour.
public enum ItemIcon {

    /// What the icon should show when there is no bundle to ask.
    public enum Role: Equatable, Sendable {
        case folder
        case file
        case systemService
        case commandLineTool
        case helper
        case unknown

        var symbolName: String {
            switch self {
            case .folder: return "folder.fill"
            case .file: return "doc.fill"
            case .systemService: return "gearshape.2.fill"
            case .commandLineTool: return "terminal.fill"
            case .helper: return "puzzlepiece.extension.fill"
            case .unknown: return "questionmark"
            }
        }

        public static func of(_ kind: RunningProcessIdentity.Kind) -> Role {
            switch kind {
            case .application: return .unknown
            case .systemService: return .systemService
            case .helper: return .helper
            case .commandLineTool: return .commandLineTool
            case .other: return .unknown
            }
        }

        /// What sits at a path, asked of the filesystem rather than guessed
        /// from the extension.
        public static func at(_ url: URL) -> Role {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            else { return .unknown }
            return isDirectory.boolValue ? .folder : .file
        }
    }

    /// A stable colour for a name.
    ///
    /// Derived from the string so the same service is the same colour in
    /// every list and across launches. A hash rather than a stored table:
    /// there is nothing to keep in step and nothing to migrate.
    ///
    /// The hues are spaced around the wheel and the saturation kept
    /// moderate, so a column of these reads as a set rather than as a
    /// warning. Deliberately not red, which in this product means something.
    public static func colour(for name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.lowercased().utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        // Twelve hues, skipping the reds at the top of the wheel.
        let step = Double(hash % 12)
        let hue = 0.08 + (step / 12) * 0.84
        return Color(hue: hue, saturation: 0.52, brightness: 0.82)
    }
}

/// The icon for one row.
public struct ItemIconView: View {
    private let bundleURL: URL?
    private let role: ItemIcon.Role
    private let name: String
    private let size: CGFloat

    /// - Parameters:
    ///   - bundleURL: the bundle to take a real icon from, when there is one.
    ///   - role: what to draw instead when there is not.
    ///   - name: what the colour is derived from, so it stays put.
    public init(bundleURL: URL?, role: ItemIcon.Role, name: String, size: CGFloat = 28) {
        self.bundleURL = bundleURL
        self.role = role
        self.name = name
        self.size = size
    }

    public var body: some View {
        Group {
            if let bundleURL {
                Image(nsImage: AppIcon.image(for: bundleURL, size: size))
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                placeholder
            }
        }
        // The name is beside it in every list that uses this, so announcing
        // the icon as well would say everything twice.
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        let tint = ItemIcon.colour(for: name)
        return RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(tint.opacity(0.22))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            }
            .overlay {
                Image(systemName: role.symbolName)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: size, height: size)
    }
}
