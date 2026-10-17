import AppKit
import BrimCore
import Foundation
import os

/// Application icons kept after the app has gone, since a leftover is most
/// recognisable by its app's icon. Each installed app's icon is saved as a
/// 64 pixel PNG, keyed by bundle identifier, in Brim's own support folder.
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

    /// Whether an icon is saved for this app, answered from memory: rows ask
    /// while drawing. The folder is listed once and kept current by saves and
    /// clears.
    public func has(_ bundleID: String) -> Bool {
        let name = url(for: bundleID).lastPathComponent
        return Self.saved.withLock { cache in
            if cache[directory.path] == nil {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                cache[directory.path] = Set(names)
            }
            return cache[directory.path]?.contains(name) ?? false
        }
    }

    /// Saved file names, per folder.
    private static let saved = OSAllocatedUnfairLock(initialState: [String: Set<String>]())

    private func noteSaved(_ file: URL) {
        _ = Self.saved.withLock { cache in
            cache[directory.path]?.insert(file.lastPathComponent)
        }
    }

    /// Saves an installed app's icon unless a copy at least as new as the
    /// bundle is here. Off the main thread, so launch rendering never holds up
    /// a scroll.
    public func remember(appAt appURL: URL, bundleID: String) {
        let target = url(for: bundleID)
        if let saved = Self.modified(target), let bundle = Self.modified(appURL), saved >= bundle {
            return
        }
        guard let png = Self.png(of: NSWorkspace.shared.icon(forFile: appURL.path)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if (try? png.write(to: target, options: .atomic)) != nil {
            noteSaved(target)
        }
    }

    /// How many icons are saved and the space they take, for Settings.
    public func footprint() -> (count: Int, bytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let pngs = files.filter { $0.pathExtension == "png" }
        let bytes = pngs.reduce(Int64(0)) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (pngs.count, bytes)
    }

    /// Clears every saved icon, when the person asks in Settings. Installed
    /// apps' icons come back on the next scan; removed apps' do not.
    public func forgetAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "png" {
            try? FileManager.default.removeItem(at: file)
        }
        Self.saved.withLock { cache in
            cache[directory.path] = nil
        }
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
    /// representation.
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
