import AppIntents
import Foundation

/// An installed application, as Shortcuts and Spotlight offer it.
nonisolated struct InstalledAppEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "App")
    static let defaultQuery = InstalledAppQuery()

    /// The bundle's path, which is what Brim keys an app on.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// The applications in the two Applications folders. Read by path, not
/// URL: `contentsOfDirectory(at:)` skips Safari (`CLAUDE.md`).
nonisolated struct InstalledAppQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [InstalledAppEntity] {
        identifiers.compactMap { path in
            FileManager.default.fileExists(atPath: path) ? Self.entity(path) : nil
        }
    }

    func entities(matching string: String) async throws -> [InstalledAppEntity] {
        Self.all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [InstalledAppEntity] {
        Self.all()
    }

    private static func all() -> [InstalledAppEntity] {
        let folders = ["/Applications", NSHomeDirectory() + "/Applications"]
        return folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { entity(folder + "/" + $0) }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func entity(_ path: String) -> InstalledAppEntity {
        InstalledAppEntity(id: path, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    }
}

/// "Remove an app with Brim". Opens that app's review in Brim's window and
/// stops there. Approval comes from a person in the window or not at all
/// (`CLAUDE.md`), and an intent is neither.
struct RemoveAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove an App"
    static let description = IntentDescription("Opens the app's review in Brim")
    static let openAppWhenRun = true

    @Parameter(title: "App")
    var app: InstalledAppEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        ExternalRequests.shared.send(.remove(URL(fileURLWithPath: app.id)))
        return .result()
    }
}

nonisolated struct BrimShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RemoveAppIntent(),
            phrases: [
                "Remove an app with \(.applicationName)",
                "Uninstall an app with \(.applicationName)"
            ],
            shortTitle: "Remove an App",
            systemImageName: "trash"
        )
    }
}
