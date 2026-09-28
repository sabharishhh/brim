import BrimCore
import BrimUI
import SwiftUI

/// Every installed app, grouped by the question people bring to the list:
/// which of these could go. One app in depth on the right.
struct ApplicationsView: View {
    @ObservedObject var model: ApplicationsModel
    /// Shared with the rest of the window, so a footprint that came up short
    /// can name the setting that would complete it.
    @ObservedObject var access: FullDiskAccessModel
    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(ShellState.self) private var shell

    @SceneStorage("apps.grouping") private var grouping = AppGrouping.smart
    @SceneStorage("apps.asTable") private var asTable = false
    @State private var uninstalling: InstalledApplication?
    @State private var resetting: InstalledApplication?
    /// "Opened 3 months ago" for each app, formatted once per load.
    @State private var opened: [String: String] = [:]

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        // Fixed panes rather than an HSplitView, which relaid out the whole
        // window on every scroll (`CLAUDE.md`).
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                content
            }
            .frame(minWidth: 480, maxWidth: .infinity)
            Divider()
            inspector
                .frame(width: 360)
                .background(Palette.surface.opacity(0.5))
        }
        .task { await model.loadIfNeeded(service: service) }
        .task(id: model.applications) { opened = Self.openedText(model.applications) }
        .focusedSceneValue(\.selectedItems, SelectedItems(urls: model.selected.map { [$0.url] } ?? []))
        .sheet(item: $resetting) { application in
            UninstallSheet(application: application, service: service, intentType: .reset) {
                Task { await model.load(service: service) }
            }
        }
        .sheet(item: $uninstalling) { application in
            UninstallSheet(application: application, service: service) {
                // Drop the row at once if the bundle really is gone:
                // re-enumerating every app takes seconds, and a row that
                // outlives "nothing remains" reads as a failure.
                model.forgetIfRemoved(application)
                AppIcon.forget(application.url)
                Task { await model.load(service: service) }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Apps")
                    .font(.brimPageTitle)
                    .foregroundStyle(Palette.ink)
                if !model.applications.isEmpty {
                    Text("\(model.applications.count) · \(ByteText.short(totalBytes))")
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                }
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Checking")
                }
                Spacer()
                if !asTable {
                    Picker("Group By", selection: $grouping) {
                        ForEach(AppGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Picker("View", selection: $asTable) {
                    Image(systemName: "list.bullet.indent").tag(false).accessibilityLabel("Groups")
                    Image(systemName: "tablecells").tag(true).accessibilityLabel("Table")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search apps")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var totalBytes: Int64 {
        model.applications.reduce(0) { $0 + $1.bundleSizeBytes }
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if model.applications.isEmpty, model.isLoading {
            SkeletonRows(showsTick: false)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if let error = model.errorMessage, model.applications.isEmpty {
            EmptyState.couldNotRead(error) { Task { await model.load(service: service) } }
        } else {
            Group {
                if asTable {
                    AppTable(model: model, opened: opened)
                } else {
                    AppStacks(
                        model: model, groups: AppGrouper().groups(model.visibleApplications, by: grouping),
                        opened: opened, remove: { uninstalling = $0 }
                    )
                }
            }
            .refreshing(model.isLoading)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let app = model.selected {
            AppInspector(
                app: app, model: model, access: access, opened: opened[app.id],
                remove: { uninstalling = app }, reset: { resetting = app }
            )
            .refreshing(model.isLoading)
            // Keyed on the app and a crossfade only, so arrowing through
            // the list does not make the pane swim.
            .id(app.id)
            .transition(.opacity)
            .animation(Motion.inspector, value: app.id)
        } else {
            PanePlaceholder(symbol: "square.grid.2x2", title: "Select an app")
        }
    }

    /// Formatted once when the list loads, never while drawing a row.
    private static func openedText(_ apps: [InstalledApplication]) -> [String: String] {
        var text: [String: String] = [:]
        let now = Date()
        for app in apps {
            if app.isMigratedAndUnopened {
                text[app.id] = "Not opened on this Mac"
            } else if let lastOpened = app.lastOpened {
                text[app.id] = "Opened " + relative.localizedString(for: lastOpened, relativeTo: now)
            } else if app.addedAt != nil {
                text[app.id] = "Never opened"
            }
        }
        return text
    }
}
