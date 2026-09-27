import AppKit
import BrimCore
import Foundation

/// Application icons, kept after the application has gone.
///
/// A leftover is most recognisable by the icon of the app that left it,
/// and by the time it is a leftover that app is no longer on the disk to
/// ask. So each installed app's icon is saved as a 64 pixel PNG while it is
/// still here, keyed by bundle identifier, and the leftovers list draws
/// that instead of a monogram. Small, local, and inside Brim's own support
/// folder, so it goes when Brim does.
public struct IconMemory: Sendable {
    public let directory: URL

    /// 32 points at 2x: the size a row draws.
    static let pixels = 64

    public init(directory: URL) {
        self.directory = directory
    }

    public static let standard = IconMemory(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brim/Interface/Icons", isDirectory: true)
    )

    public func url(for bundleID: String) -> URL {
        let safe = bundleID.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".png")
    }

    public func has(_ bundleID: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: bundleID).path)
    }

    /// Saves an installed application's icon, unless a copy at least as
    /// new as the bundle is already here. Off the main thread: rendering a
    /// hundred icons at launch is exactly the work a scroll must not wait on.
    public func remember(appAt appURL: URL, bundleID: String) {
        let target = url(for: bundleID)
        if let saved = Self.modified(target), let bundle = Self.modified(appURL), saved >= bundle {
            return
        }
        guard let png = Self.png(of: NSWorkspace.shared.icon(forFile: appURL.path)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: target, options: .atomic)
    }

    /// Saves every installed app's icon, in the background.
    public func remember(_ applications: [InstalledApplication]) {
        let memory = self
        Task.detached(priority: .utility) {
            for app in applications {
                if let bundleID = app.identity.bundleID {
                    memory.remember(appAt: app.url, bundleID: bundleID)
                }
            }
        }
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Draws into a bitmap of exactly the saved size, so the file holds one
    /// representation instead of every size up to 1024.
    static func png(of icon: NSImage) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// Saved icons as images, read once each.
@MainActor
public enum RememberedIcon {
    private static let cache = NSCache<NSString, NSImage>()

    public static func image(for bundleID: String, in memory: IconMemory = .standard) -> NSImage? {
        let key = bundleID as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(contentsOf: memory.url(for: bundleID)) else { return nil }
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: key)
        return image
    }
}
