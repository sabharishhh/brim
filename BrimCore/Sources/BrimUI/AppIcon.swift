import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Application icons, fetched the way macOS intends and cached so a long
/// list costs one lookup per app rather than one per redraw.
///
/// `NSWorkspace.icon(forFile:)` is the whole answer for getting the image.
/// It resolves the icon however a given bundle happens to declare it, which
/// over the years has meant `CFBundleIconFile`, `CFBundleIconName`, an
/// asset catalog, a bare `.icns`, or a document icon inherited from the
/// type. Reading `Info.plist` by hand handles one of those and quietly gets
/// the rest wrong.
///
/// What it does not do is cache across calls in a form that is cheap to
/// hand SwiftUI. Every call returns a fresh multi representation `NSImage`,
/// and a table redrawing sixty times a second while scrolling will ask
/// again for every visible row. So the results are held here, keyed by path
/// and rendered size. Icons change about as often as an app is reinstalled,
/// which is why an `NSCache` is the right shape: it keeps them for as long
/// as there is memory to spare and quietly gives them up when there is not.
@MainActor
public enum AppIcon {

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // Generous, because these are small and re-fetching is the cost we
        // are avoiding. 86 apps at 32pt is well under this.
        cache.countLimit = 512
        return cache
    }()

    /// The generic application icon macOS itself uses. Held once rather
    /// than rebuilt, since it is the same image every time.
    ///
    /// This should effectively never be seen: every real bundle has an
    /// icon, and `NSWorkspace` substitutes the generic one itself for the
    /// odd bundle that does not. It exists for the case where there is no
    /// readable file at the path at all, which happens when an app is
    /// removed while its row is still on screen.
    private static let fallback: NSImage = NSWorkspace.shared.icon(for: .applicationBundle)

    /// The icon for an application bundle, at the size it will be drawn.
    ///
    /// - Parameter size: points. Setting it matters: an unsized icon carries
    ///   every representation up to 512pt, and drawing that into a 32pt row
    ///   makes the window server scale a bitmap sixteen times too large on
    ///   every frame.
    public static func image(for url: URL, size: CGFloat = 32) -> NSImage {
        let key = "\(url.path)@\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let icon: NSImage
        if FileManager.default.fileExists(atPath: url.path) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = fallback
        }

        // Copy before resizing: the instance NSWorkspace hands back may be
        // shared, and mutating its size would resize it everywhere.
        let sized = icon.copy() as? NSImage ?? icon
        sized.size = NSSize(width: size, height: size)

        cache.setObject(sized, forKey: key)
        return sized
    }

    /// Drops a cached icon, for when an app has been removed and the row is
    /// about to be redrawn from a path that no longer resolves.
    public static func forget(_ url: URL) {
        for size in [16, 20, 24, 32, 48, 64, 128] {
            cache.removeObject(forKey: "\(url.path)@\(CGFloat(size))" as NSString)
        }
    }
}

/// An application's icon, sized and cached.
public struct AppIconView: View {
    private let url: URL
    private let size: CGFloat

    public init(url: URL, size: CGFloat = 32) {
        self.url = url
        self.size = size
    }

    public var body: some View {
        Image(nsImage: AppIcon.image(for: url, size: size))
            .resizable()
            .frame(width: size, height: size)
            // The icon repeats the name beside it, so a screen reader
            // announcing it would just say everything twice.
            .accessibilityHidden(true)
    }
}
