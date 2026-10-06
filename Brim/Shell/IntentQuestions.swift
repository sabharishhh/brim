import AppIntents
import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

// The questions Siri can ask Brim. Each reads what the matching page shows,
// says it in a sentence and a small card, and changes nothing.

/// How much space an app takes, and where, as its inspector groups it.
struct AppSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "App's Space"
    static let description = IntentDescription("How much space an app takes, and where")

    @Parameter(title: "App")
    var app: InstalledAppEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let sources = IntentSources.shared
        guard let installed = await sources.application(at: app.id) else {
            throw IntentProblem.notInstalled(app.name)
        }
        let footprint = try await sources.service.inspect(identity: installed.identity)
        let sections = FootprintSection.arrange(footprint)
        let places = sections.reduce(0) { $0 + $1.locations.count }
        let rows = sections.map { section in
            FactsSnippet.Row(title: section.loss.title, value: ByteText.short(
                section.locations.reduce(0) { $0 + ($1.logicalBytes ?? 0) }
            ))
        }
        let size = ByteText.short(footprint.totalSizeBytes)
        let where_ = places == 1 ? "1 location" : "\(places) locations"
        return .result(
            dialog: "\(installed.name) takes \(size) in \(where_).",
            view: FactsSnippet(figure: size, caption: "\(installed.name), in \(where_)", rows: rows, page: .apps)
        )
    }
}

/// What removed apps left, as Home's Remnants card counts it.
struct RemnantsIntent: AppIntent {
    static let title: LocalizedStringResource = "Remnants"
    static let description = IntentDescription("What removed apps left on this Mac")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let (model, canSeeLibrary) = await IntentSources.shared.leftovers()
        guard model.errorMessage == nil else { throw IntentProblem.couldNotCheck("remnants") }
        let groups = model.orphanedGroups
        let unclaimed = model.unclaimedGroupsForReview.count
        let size = HomeRemnantsSize(groups: groups, unclaimed: unclaimed)
        let status = HomeStatus.leftovers(.init(
            removedApps: groups.count, unclaimed: unclaimed, hasChecked: true, canSeeLibrary: canSeeLibrary
        ))
        let rows = groups.sorted { $0.totalBytes > $1.totalBytes }.prefix(5).map {
            FactsSnippet.Row(title: $0.displayName, value: ByteText.short($0.totalBytes))
        }
        let dialog = groups.isEmpty ? "\(status.phrase)." : "\(size.figure), \(status.phrase.lowercased())."
        return .result(
            dialog: "\(dialog)",
            view: FactsSnippet(figure: size.figure, caption: status.phrase, rows: Array(rows), page: .remnants)
        )
    }
}

/// What runs in the background, as Home's Background card counts it.
struct BackgroundIntent: AppIntent {
    static let title: LocalizedStringResource = "Background"
    static let description = IntentDescription("What runs in the background, and whether it all belongs to installed apps")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let model = await IntentSources.shared.background()
        let status = HomeStatus.background(leftOver: model.stale.count, hasChecked: true,
                                           hasFaults: !model.faults.isEmpty)
        let figure = "\(model.live.count) listed"
        let leftOver = Set(model.stale.map(\.id))
        let rows = (model.stale + model.live).prefix(6).map {
            FactsSnippet.Row(title: $0.displayName, value: leftOver.contains($0.id) ? "Left over" : "")
        }
        return .result(
            dialog: "\(figure). \(status.phrase).",
            view: FactsSnippet(figure: figure, caption: status.phrase, rows: Array(rows), page: .background)
        )
    }
}

/// Which apps have a newer version, as the Updates page found them.
struct UpdatesIntent: AppIntent {
    static let title: LocalizedStringResource = "Updates"
    static let description = IntentDescription("Which apps have a newer version")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let model = await IntentSources.shared.updates()
        guard let pending = model.pending else { throw IntentProblem.couldNotCheck("updates") }
        let checked = model.check.map { "Checked \($0.checked) apps" } ?? ""
        let rows = pending.prefix(6).map {
            FactsSnippet.Row(title: $0.name, value: "\($0.installedVersion) to \($0.latestVersion)")
        }
        let figure = "\(pending.count) available"
        let dialog = switch pending.count {
        case 0: "Your apps are up to date."
        case 1: "\(pending[0].name) has an update."
        default: "\(pending.count) apps have updates."
        }
        return .result(
            dialog: "\(dialog)",
            view: FactsSnippet(figure: figure, caption: checked, rows: Array(rows), page: .updates)
        )
    }
}

/// Opens a page of Brim, from a card's button.
struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in Brim"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "Page")
    var page: BrimPage

    init() {}

    init(page: BrimPage) {
        self.page = page
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let page = page
        IntentSources.shared.inWindow { shell, _ in
            switch page {
            case .apps: shell.go(to: .apps, lens: .all)
            case .updates: shell.go(to: .apps, lens: .updates)
            case .remnants: shell.go(to: .leftovers)
            case .background: shell.go(to: .background)
            }
        }
        return .result()
    }
}

enum BrimPage: String, AppEnum {
    case apps, updates, remnants, background

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Page")
    static let caseDisplayRepresentations: [BrimPage: DisplayRepresentation] = [
        .apps: "Apps", .updates: "Updates", .remnants: "Remnants", .background: "Background"
    ]
}

enum IntentProblem: Error, CustomLocalizedStringResourceConvertible {
    case notInstalled(String)
    case couldNotCheck(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case let .notInstalled(name): "\(name) is no longer installed."
        case let .couldNotCheck(what): "Brim could not check \(what). Open Brim to see why."
        }
    }
}

/// The card under Siri's answer: the figure, a line, a few rows, and a way
/// into Brim. Plain system styles, because it is drawn on Siri's surface.
struct FactsSnippet: View {
    struct Row: Hashable {
        let title: String
        let value: String
    }

    let figure: String
    let caption: String
    let rows: [Row]
    let page: BrimPage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(figure).font(.title2.weight(.semibold))
                if !caption.isEmpty {
                    Text(caption).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !rows.isEmpty {
                VStack(spacing: 6) {
                    ForEach(rows, id: \.self) { row in
                        HStack {
                            Text(row.title).lineLimit(1)
                            Spacer()
                            Text(row.value).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
            Button(intent: OpenPageIntent(page: page)) {
                Text("Open in Brim")
            }
        }
        .padding()
    }
}
