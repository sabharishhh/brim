import AppKit
import BrimCore
import BrimOps
import BrimScan
import Foundation

public extension BrimService {
    func previewInstaller(at url: URL) async throws -> InstallerPreview {
        // Nothing but a local file is read. `hdiutil` would also take a web
        // address, and a preview must never reach for one.
        guard url.isFileURL, url.path.hasPrefix("/") else { throw InstallerReadError.notAnInstaller }
        var installed: [String: InstallerReader.Installed] = [:]
        for app in await applicationInventoryRead().value {
            guard let identifier = app.identity.bundleID?.lowercased(), installed[identifier] == nil else { continue }
            installed[identifier] = .init(version: app.version, path: app.url.path)
        }
        let reader = InstallerReader(installed: installed, root: root, icon: Self.iconPNG)
        // Off the service's actor: mounting an image or listing a large
        // package takes seconds, and every other request would wait.
        return try await Task.detached(priority: .userInitiated) { try reader.read(url) }.value
    }

    func installApplication(
        from source: URL, identifier: String?, trusted: Bool, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard source.isFileURL, source.path.hasPrefix("/") else { throw AppInstaller.Failure.unreadable }
        // Off the actor, like reading: mounting and copying take seconds.
        return try await Task.detached(priority: .userInitiated) {
            try AppInstaller.install(from: source, identifier: identifier, trusted: trusted, progress: progress)
        }.value
    }

    /// The icon at the size the preview draws it, twice over for Retina.
    /// Drawn into a bitmap of that size: an icon's TIFF carries every size
    /// up to 1024 pixels, and its first is not the one wanted. The context
    /// is made before the bitmap is given a point size, so it works in
    /// pixels and the icon fills all of them; drawing into 64 points there
    /// filled the bottom left quarter, and the preview showed a speck.
    private static let iconPNG: @Sendable (URL) -> Data? = { url in
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let pixels = 128
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: 64, height: 64)
        return bitmap.representation(using: .png, properties: [:])
    }
}
