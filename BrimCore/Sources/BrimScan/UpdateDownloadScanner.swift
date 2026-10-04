import BrimCore
import CoreServices
import Foundation

/// Copies of updates that apps downloaded to install themselves.
///
/// An app that updates itself downloads the whole new version first, and
/// the copy often stays after it is installed. Antigravity kept the same
/// 181 MB update twice, and VS Code and Claude together held 2.3 GB of
/// updates already installed. There are three ways apps do this, and one
/// rule reads all of them:
///
/// - Squirrel keeps `update.*` beside its state in `<identifier>.ShipIt`.
/// - electron-updater keeps a zip in a `pending` folder, and sometimes an
///   `update.zip` beside it, in a cache named for the app.
/// - Sparkle keeps `org.sparkle-project.Sparkle` inside the app's cache.
///
/// Only updates for an app still installed are listed here; the rest are
/// what a removed app left behind. Brim clears a copy itself only when it
/// is spent: the app was put in place after the download, the staged
/// version is not newer than the one installed, or the download never
/// finished and has sat for a week. An update waiting for its app to
/// restart is shown and left alone.
public struct UpdateDownloadScanner: Sendable {
    public typealias Resolve = @Sendable (_ identifierOrName: String) -> URL?

    private let resolve: Resolve

    public init(resolve: @escaping Resolve = UpdateDownloadScanner.installedApp) {
        self.resolve = resolve
    }

    public func scan(home: URL, now: Date = Date()) -> [DeveloperCache] {
        var found: [DeveloperCache] = []
        let candidates = [home.appendingPathComponent("Library/Caches"),
                          home.appendingPathComponent("Library/Application Support/Caches")]
        for cacheRoot in candidates {
            for folder in Self.children(of: cacheRoot) {
                if Task.isCancelled {
                    return found
                }
                let name = folder.lastPathComponent
                if name.hasSuffix(".ShipIt") {
                    guard let app = resolve(String(name.dropLast(".ShipIt".count))) else { continue }
                    found += squirrel(folder, app: app)
                } else {
                    let owner = name.hasSuffix("-updater") ? String(name.dropLast("-updater".count)) : name
                    guard let app = resolve(owner) else { continue }
                    found += electron(folder, app: app, now: now) + sparkle(folder, app: app)
                }
            }
        }
        return found.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Squirrel stages each update in its own `update.*` folder holding the
    /// new app, so the version is read from the staged bundle itself.
    func squirrel(_ folder: URL, app: URL) -> [DeveloperCache] {
        Self.children(of: folder).filter { $0.lastPathComponent.hasPrefix("update.") }.compactMap { staged in
            let bundle = Self.children(of: staged).first { $0.pathExtension == "app" }
            let spent = bundle.map { !VersionOrder.isNewer(Self.version($0), than: Self.version(app)) } ?? true
            return item(staged, app: app, state: spent ? .installed : .waiting)
        }
    }

    /// electron-updater's zip carries no version, so the dates decide: a
    /// download the installed app is newer than has been installed. Each
    /// zip is its own row, and the small note beside it that names the file
    /// stays; without the file the updater downloads again.
    func electron(_ folder: URL, app: URL, now: Date) -> [DeveloperCache] {
        let pending = Self.children(of: folder.appendingPathComponent("pending")).filter { $0.pathExtension == "zip" }
        let zip = folder.appendingPathComponent("update.zip")
        let files = pending + (FileManager.default.fileExists(atPath: zip.path) ? [zip] : [])
        return files.compactMap { file in
            let downloaded = Self.modified(file)
            let unfinished = file.lastPathComponent.hasPrefix("temp-")
                && now.timeIntervalSince(downloaded) > 7 * 24 * 60 * 60
            let state: State = if unfinished {
                .unfinished(downloaded)
            } else if Self.placed(app) >= downloaded {
                .installed
            } else {
                .waiting
            }
            return item(file, app: app, state: state)
        }
    }

    func sparkle(_ folder: URL, app: URL) -> [DeveloperCache] {
        let sparkle = folder.appendingPathComponent("org.sparkle-project.Sparkle")
        guard Self.isFolder(sparkle) else { return [] }
        let state: State = Self.placed(app) >= Self.modified(sparkle) ? .installed : .waiting
        return item(sparkle, app: app, state: state).map { [$0] } ?? []
    }

    enum State {
        case installed, waiting, unfinished(Date)
    }

    private func item(_ url: URL, app: URL, state: State) -> DeveloperCache? {
        let size = ArtifactSizer.measure(at: url)
        guard !size.isEmpty else { return nil }
        let name = app.deletingPathExtension().lastPathComponent
        let title: String, explanation: String
        let cost: DeveloperCache.Cost
        switch state {
        case .installed:
            title = "Installed update"
            explanation = "\(name) has installed this update already. Nothing uses the copy."
            cost = .rebuilt
        case let .unfinished(date):
            title = "Unfinished update"
            explanation = "A download \(name) started on \(date.formatted(.dateTime.day().month())) and never finished."
            cost = .rebuilt
        case .waiting:
            title = "Update waiting to install"
            explanation = "\(name) installs this the next time it restarts. Left for \(name) to use."
            cost = .configured
        }
        return DeveloperCache(name: title, tool: name, url: url, sizeBytes: size.allocatedBytes, cost: cost,
                              explanation: explanation, app: app, sizeMeasurement: size,
                              artifactClassification: cost == .rebuilt ? .rebuildableCache : .stateful)
    }

    // MARK: - Reading the disk

    static func children(of folder: URL) -> [URL] {
        guard case let .listed(names) = DirectoryEntries.read(folder) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.map { folder.appendingPathComponent($0) }
    }

    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    static func version(_ bundle: URL) -> String {
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The newest change to the path or anything directly inside it.
    static func modified(_ url: URL) -> Date {
        ([url] + children(of: url)).compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max() ?? .distantPast
    }

    /// When the installed copy of the app was put where it is. An updater
    /// replaces the whole bundle, so this moves with every update.
    static func placed(_ app: URL) -> Date {
        let values = try? app.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast
    }

    /// The installed app a cache folder is named for: by identifier through
    /// Launch Services, otherwise by name in the Applications folders.
    public static let installedApp: Resolve = { key in
        if key.contains(".") {
            let urls = LSCopyApplicationURLsForBundleIdentifier(key as CFString, nil)?.takeRetainedValue() as? [URL]
            if let urls {
                if let app = urls.first(where: {
                    !$0.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: $0.path)
                }) {
                    return app
                }
            }
        }
        guard !key.contains(".") else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            if let app = children(of: folder).first(where: {
                $0.pathExtension == "app"
                    && $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(key) == .orderedSame
            }) {
                return app
            }
        }
        return nil
    }
}
