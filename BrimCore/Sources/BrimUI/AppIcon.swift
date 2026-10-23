import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Application icons, fetched the way macOS intends and cached per path and
/// size. `NSWorkspace.icon(forFile:)` handles every way a bundle declares
/// its icon; reading `Info.plist` by hand gets most of them wrong. It returns
/// a fresh image each call, so a scrolling list would ask again for every
/// visible row; an `NSCache` keeps them while there is memory to spare.
@MainActor
public enum AppIcon {

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // Generous: these are small, and re-fetching is the cost avoided.
        cache.countLimit = 512
        return cache
    }()

    /// The generic application icon, for a path with no readable file, such as
    /// an app removed while its row is still on screen.
    private static let fallback: NSImage = NSWorkspace.shared.icon(for: .applicationBundle)

    /// The icon for an application bundle, at the size it will be drawn.
    /// - Parameter size: points. An unsized icon carries every representation up
    ///   to 512 pt, and the window server would scale that on every frame.
    public static func image(for url: URL, size: CGFloat = 32) -> NSImage {
        let key = "\(url.path)@\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let icon: NSImage
        if FileManager.default.fileExists(atPath: url.path) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = fallback
        }

        // Copy before resizing: the image NSWorkspace returns may be shared.
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
