import AppIntents
import BrimCore
import BrimUI
import CoreSpotlight
import Foundation

/// An installed application, as Siri, Spotlight and Shortcuts know it.
/// Indexed with its developer, size and when it was last opened, so Siri
/// can find one by what it is rather than only by its name.
nonisolated struct InstalledAppEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "App", numericFormat: "\(placeholder: .int) apps"
    )
    static let defaultQuery = InstalledAppQuery()

    /// The bundle's path, which is what Brim keys an app on.
    let id: String
    @Property(title: "Name") var name: String
    @Property(title: "Developer") var developer: String?
    @Property(title: "Size") var size: Measurement<UnitInformationStorage>
    @Property(title: "Last Opened") var lastOpened: Date?
    let icon: Data?

    init(_ app: InstalledApplication, icon: Data?) {
        id = app.id
        self.icon = icon
        name = app.name
        developer = app.developer
        size = Measurement(value: Double(app.bundleSizeBytes), unit: .bytes)
        lastOpened = app.lastOpened
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)", subtitle: "\(summary)", image: icon.map { .init(data: $0) }
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.displayName = name
        set.contentDescription = summary
        set.keywords = [developer, "app", "application"].compactMap(\.self)
        set.lastUsedDate = lastOpened
        return set
    }

    private var summary: String {
        let bytes = ByteText.short(Int64(size.converted(to: .bytes).value))
        return [developer, bytes].compactMap(\.self).joined(separator: " · ")
    }
}

/// The installed apps Brim lists, Apple's own left out: macOS protects
/// them, so offering one to remove would only ever end in a refusal.
nonisolated struct InstalledAppQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [InstalledAppEntity] {
        await MainActor.run { IntentSources.shared }.entities(identifiers)
    }

    func entities(matching string: String) async throws -> [InstalledAppEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [InstalledAppEntity] {
        await MainActor.run { IntentSources.shared }.allEntities()
    }
}

extension IntentSources {
    func allEntities() async -> [InstalledAppEntity] {
        await applications().map(entity)
    }

    func entities(_ identifiers: [String]) async -> [InstalledAppEntity] {
        let apps = await applications()
        return identifiers.compactMap { id in apps.first { $0.id == id }.map(entity) }
    }
}

/// "Remove an app with Brim". Opens that app's review in Brim's window, the
/// plan ready and Remove the default button, and stops there. Siri asking
/// "are you sure" is not a person approving in Brim's window: a voice can
/// be anyone's, and text on the screen can set an intent off. Approval
/// comes from the window or not at all (`CLAUDE.md`).
struct RemoveAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove an App"
    static let description = IntentDescription("Opens the app's review in Brim, ready to remove")
    static let openAppWhenRun = true

    @Parameter(title: "App")
    var app: InstalledAppEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        ExternalRequests.shared.send(.remove(URL(fileURLWithPath: app.id)))
        return .result()
    }
}

/// "Search Brim for Adobe": the Apps list, filtered.
@AppIntent(schema: .system.searchInApp)
struct SearchAppsIntent {
    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        let term = criteria.term
        IntentSources.shared.inWindow { shell, models in
            shell.go(to: .apps, lens: .all)
            models.applications.searchText = term
        }
        return .result()
    }
}

nonisolated struct BrimShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RemoveAppIntent(),
            phrases: [
                "Remove \(\.$app) with \(.applicationName)",
                "Uninstall \(\.$app) with \(.applicationName)",
                "Remove an app with \(.applicationName)",
                "Uninstall an app with \(.applicationName)"
            ],
            shortTitle: "Remove an App",
            systemImageName: "trash"
        )
        AppShortcut(
            intent: AppSpaceIntent(),
            phrases: [
                "How much space does \(\.$app) take in \(.applicationName)",
                "Check an app's space in \(.applicationName)"
            ],
            shortTitle: "App's Space",
            systemImageName: "internaldrive"
        )
        AppShortcut(
            intent: RemnantsIntent(),
            phrases: [
                "What did removed apps leave in \(.applicationName)",
                "Check remnants in \(.applicationName)"
            ],
            shortTitle: "Remnants",
            systemImageName: "app.dashed"
        )
        AppShortcut(
            intent: BackgroundIntent(),
            phrases: [
                "What runs in the background in \(.applicationName)",
                "Check background items in \(.applicationName)"
            ],
            shortTitle: "Background",
            systemImageName: "gearshape.2"
        )
        AppShortcut(
            intent: UpdatesIntent(),
            phrases: [
                "Check app updates in \(.applicationName)",
                "Are there app updates in \(.applicationName)"
            ],
            shortTitle: "Updates",
            systemImageName: "arrow.down.circle"
        )
    }
}
