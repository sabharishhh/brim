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
    /// The removal or reset under review in the right pane, if any.
    @State private var review: AppReview?
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .frame(minWidth: Metrics.listMinWidth, maxWidth: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { ShellOverlay(tray: nil) }
            // Held still while a review is open, and dimmed a little so the
            // review reads as the focus.
            .opacity(review == nil ? 1 : 0.55)
            .allowsHitTesting(review == nil)
            inspector
                // Wider for a review, whose rows carry more.
                .frame(width: review == nil ? 360 : 440)
        }
        .animation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion), value: review?.id)
        .task { await model.loadIfNeeded(service: service) }
        .task(id: model.applications) { opened = Self.openedText(model.applications) }
        // A removal asked for by a Shortcut or Spotlight: the review opens
        // here and waits for the person, like any other.
        .task(id: PendingKey(url: shell.pendingRemoval, loaded: model.applications.count)) { openPendingReview() }
        .focusedSceneValue(\.selectedItems, SelectedItems(urls: model.selected.map { [$0.url] } ?? []))
    }

    private struct PendingKey: Equatable {
        let url: URL?
        let loaded: Int
    }

    private func openPendingReview() {
        guard let url = shell.pendingRemoval, !model.applications.isEmpty else { return }
        shell.pendingRemoval = nil
        guard model.selectApplication(at: url), let app = model.selected else {
            shell.show(ToastMessage(
                symbol: "questionmark.app", text: "\(url.deletingPathExtension().lastPathComponent) is not in the list"
            ))
            return
        }
        review = AppReview(app: app, type: .uninstall)
    }

    private func finished(_ review: AppReview) {
        if review.type == .uninstall {
            // Drop the row at once if the bundle really is gone:
            // re-enumerating every app takes seconds, and a row that
            // outlives "nothing left" reads as a failure.
            model.forgetIfRemoved(review.app)
            AppIcon.forget(review.app.url)
        }
        Task { await model.load(service: service) }
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
        .padding(.horizontal, 24)
        .padding(.top, 18)
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
                        opened: opened, remove: { review = AppReview(app: $0, type: .uninstall) }
                    )
                    // A new grouping is a new order to hold.
                    .id(grouping)
                }
            }
            .refreshing(model.isLoading)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let review {
            UninstallPanel(
                application: review.app, service: service, intentType: review.type,
                onFinished: { finished(review) },
                onClose: { self.review = nil }
            )
            .id(review.id)
            .transition(.opacity)
        } else if let app = model.selected {
            AppInspector(
                app: app, model: model, access: access, opened: opened[app.id],
                remove: { review = AppReview(app: app, type: .uninstall) },
                reset: { review = AppReview(app: app, type: .reset) }
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

/// An app and what is being done to it, for the review in the right pane.
struct AppReview: Identifiable, Equatable {
    let app: InstalledApplication
    let type: IntentType
    var id: String {
        "\(type.rawValue):\(app.id)"
    }
}
