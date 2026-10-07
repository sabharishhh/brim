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
    /// Apps being removed together, in the right pane.
    @State private var batch: [InstalledApplication]?
    /// The removal under review in the right pane, if any.
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
        AdaptivePanes(
            detailWidth: Metrics.detailWidth,
            hasDetail: review != nil || batch != nil || model.isChoosing
                || model.marked.count >= 2 || model.selected != nil,
            isReviewing: review != nil || batch != nil,
            close: closeDetail
        ) {
            VStack(spacing: 0) {
                header
                content
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { ShellOverlay(tray: nil) }
            // Held still while a review is open, and dimmed a little so the
            // review reads as the focus.
            .opacity(review == nil ? 1 : 0.55)
            .allowsHitTesting(review == nil)
        } detail: {
            inspector
        }
        .animation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion), value: review?.id)
        .pageTitle("Apps", shown: false)
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
        review = AppReview(app: removalTarget(app))
    }

    /// The floating pane's Close, in a narrow window: ends choosing, or
    /// clears the selection it was showing.
    private func closeDetail() {
        if model.isChoosing {
            model.stopChoosing()
        } else {
            model.select(nil)
        }
    }

    /// What removing an app removes. An app shipped inside another cannot
    /// be taken out of it without breaking the host's signature, so its
    /// removal is the host's, and the review says so by showing the host.
    private func removalTarget(_ app: InstalledApplication) -> InstalledApplication {
        guard let host = app.hostURL else { return app }
        return model.applications.first { $0.url.path == host.path } ?? app
    }

    private func finished(_ review: AppReview) {
        // Drop the row at once if the bundle really is gone:
        // re-enumerating every app takes seconds, and a row that
        // outlives "nothing left" reads as a failure.
        model.forgetIfRemoved(review.app)
        AppIcon.forget(review.app.url)
        Task { await model.load(service: service) }
    }

    // MARK: - Header

    /// The search and the list's controls, on one row at the top of the
    /// list. The Apps and Updates switch in the toolbar names the page.
    private var header: some View {
        HStack(spacing: 8) {
            BrimSearchField(text: $model.searchText, prompt: "Search Apps")
            if !asTable {
                Picker("Group By", selection: $grouping) {
                    ForEach(AppGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            // Several apps in one review. Command-click did this and
            // nobody found it.
            Button(model.isChoosing ? "Done" : "Select") {
                model.isChoosing ? model.stopChoosing() : model.startChoosing()
            }
            .disabled(model.applications.isEmpty)
            ViewToggle(asTable: $asTable)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 6)
        .padding(.bottom, 8)
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
        } else if model.visibleApplications.isEmpty, !model.searchText.isEmpty {
            // A blank list after a search read as the list failing to load.
            EmptyState(symbol: "magnifyingglass", title: "No matches",
                       message: "No installed app matches \"\(model.searchText)\"")
        } else {
            Group {
                if asTable {
                    AppTable(model: model, opened: opened)
                } else {
                    AppStacks(
                        model: model, groups: AppGrouper().groups(model.visibleApplications, by: grouping),
                        opened: opened, remove: { review = AppReview(app: removalTarget($0)) }
                    )
                    // A new grouping is a new order to hold.
                    .id(grouping)
                }
            }
            .refreshingBrowsable(model.isLoading)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let review {
            UninstallPanel(
                application: review.app, service: service,
                onFinished: { finished(review) },
                onClose: { self.review = nil }
            )
            .id(review.id)
            .transition(.paneSwap(reduceMotion: reduceMotion))
        } else if let batch {
            BatchRemovalPanel(
                apps: batch, service: service,
                // The list catches up as soon as the apps have gone, not
                // when the panel is closed.
                onRemoved: {
                    batch.forEach { model.forgetIfRemoved($0); AppIcon.forget($0.url) }
                    Task { await model.load(service: service) }
                },
                onFinished: {
                    self.batch = nil
                    model.stopChoosing()
                },
                onClose: { self.batch = nil }
            )
            .id(batch.map(\.id).joined(separator: ","))
            .transition(.paneSwap(reduceMotion: reduceMotion))
        } else if model.marked.count >= 2 || model.isChoosing {
            MarkedApps(apps: model.marked) {
                if model.marked.count == 1, let app = model.marked.first {
                    review = AppReview(app: removalTarget(app))
                    model.stopChoosing()
                } else {
                    batch = model.marked.map(removalTarget)
                }
            }
            .transition(.replacement)
        } else if let app = model.selected {
            AppInspector(
                app: app, model: model, access: access, opened: opened[app.id],
                remove: { review = AppReview(app: removalTarget(app)) }
            )
            .refreshingBrowsable(model.isLoading)
            // Keyed on the app and a crossfade only, so arrowing through
            // the list does not make the pane swim.
            .id(app.id)
            .transition(.replacement)
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
    var id: String {
        app.id
    }
}

/// The apps ticked with Select or Command-click, before their review.
private struct MarkedApps: View {
    let apps: [InstalledApplication]
    let review: () -> Void

    var body: some View {
        if apps.isEmpty {
            PanePlaceholder(symbol: "checkmark.circle", title: "Tick the apps to remove")
        } else {
            chosen
        }
    }

    private var chosen: some View {
        VStack(spacing: 16) {
            HStack(spacing: -10) {
                ForEach(apps.prefix(5)) { app in
                    BrimIcon(source: .bundle(app.url), size: 48)
                }
            }
            .accessibilityHidden(true)
            Text(apps.count == 1 ? "1 app selected" : "\(apps.count) apps selected")
                .font(.brimPageTitle)
                .foregroundStyle(Palette.ink)
            Text(ByteText.short(apps.reduce(0) { $0 + $1.bundleSizeBytes }))
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkSecondary)
            Button(apps.count == 1 ? "Review" : "Remove \(apps.count) Apps", action: review)
                .capsuleAction(prominent: true)
                .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Groups or table, drawn by Brim. The system's segmented control fills
/// the chosen segment with the accent, which Brim keeps grey; the chosen
/// one is off-white with a near-black symbol, as the Apps and Updates
/// switch is.
private struct ViewToggle: View {
    @Binding var asTable: Bool

    var body: some View {
        HStack(spacing: 2) {
            option("list.bullet.indent", "Groups", table: false)
            option("tablecells", "Table", table: true)
        }
        .padding(2)
        .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }

    private func option(_ symbol: String, _ label: String, table: Bool) -> some View {
        let isOn = asTable == table
        return Button {
            asTable = table
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Palette.onSnow : Palette.inkSecondary)
                .frame(width: 28, height: 22)
                .background(isOn ? Palette.snow : .clear, in: .rect(cornerRadius: 5, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
