import AppIntents
import AppKit
import BrimCore
import BrimProtocol
import BrimUI
import CoreSpotlight

/// What Siri, Spotlight and Shortcuts read Brim's answers from.
///
/// The window's own models when there is a window, so a spoken answer is
/// the figure Home shows; otherwise models of its own, loaded on the first
/// question. Either way the one shared service does the reading.
@MainActor
final class IntentSources {
    static let shared = IntentSources()

    private weak var models: SectionModels?
    private weak var shell: ShellState?
    private lazy var ownModels = SectionModels()
    /// A request that arrived before the window did.
    private var waiting: ((ShellState, SectionModels) -> Void)?
    private var indexed: Set<String> = []
    private var icons: [String: Data] = [:]

    var service: any BrimServiceProtocol {
        BrimServiceLocator.shared
    }

    private var current: SectionModels {
        models ?? ownModels
    }

    func attach(models: SectionModels, shell: ShellState) {
        self.models = models
        self.shell = shell
        waiting?(shell, models)
        waiting = nil
    }

    /// Runs `action` in the window, now or once it exists, and brings Brim
    /// forward.
    func inWindow(_ action: @escaping (ShellState, SectionModels) -> Void) {
        NSApp.activate()
        if let shell, let models {
            action(shell, models)
        } else {
            waiting = action
        }
    }

    // MARK: - Answers

    func applications() async -> [InstalledApplication] {
        let model = current.applications
        await model.loadIfNeeded(service: service)
        await settle { model.isLoading }
        return model.applications.filter { !$0.isSystemProtected }
    }

    func application(at path: String) async -> InstalledApplication? {
        await applications().first { $0.id == path }
    }

    func leftovers() async -> (model: LeftoversModel, canSeeLibrary: Bool) {
        let model = current.leftovers
        await model.loadIfNeeded(service: service)
        await settle { model.checkedAt == nil && model.errorMessage == nil }
        return (model, current.fullDiskAccess.isGranted)
    }

    func background() async -> BackgroundModel {
        let model = current.background
        await model.loadIfNeeded(service: service)
        await settle { model.isLoading }
        return model
    }

    func updates() async -> UpdatesModel {
        let model = current.updates
        await model.loadIfNeeded(service: service)
        await settle { model.isChecking }
        return model
    }

    /// Another caller may have started the load; wait for it, within reason.
    private func settle(_ isBusy: () -> Bool) async {
        for _ in 0 ..< 200 where isBusy() {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Spotlight

    func entity(_ app: InstalledApplication) -> InstalledAppEntity {
        InstalledAppEntity(app, icon: icon(for: app.url))
    }

    /// Puts the installed apps in Spotlight's index, so Siri can find one by
    /// what it is ("the video editor I never open"), and takes out the ones
    /// that have gone.
    func index(_ apps: [InstalledApplication]) {
        let entities = apps.filter { !$0.isSystemProtected }.map(entity)
        let ids = Set(entities.map(\.id))
        let gone = Array(indexed.subtracting(ids))
        indexed = ids
        Task {
            let index = CSSearchableIndex.default()
            try? await index.indexAppEntities(entities)
            if !gone.isEmpty {
                try? await index.deleteAppEntities(identifiedBy: gone, ofType: InstalledAppEntity.self)
            }
            BrimShortcuts.updateAppShortcutParameters()
        }
    }

    /// Sized once, as `CLAUDE.md` asks of every app icon.
    private func icon(for url: URL) -> Data? {
        if let cached = icons[url.path] {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let side = 64
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let data = bitmap.representation(using: .png, properties: [:])
        icons[url.path] = data
        return data
    }
}
