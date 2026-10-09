import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// Which applications have a newer version, and putting it in place.
///
/// The section used to describe how each application updates, grouped as
/// "update themselves" and "you update yourself", and listed background
/// updater jobs including ones for software that had gone. None of it said
/// whether anything needed updating. It now lists updates, and nothing else.
struct UpdatesView: View {
    @ObservedObject var model: UpdatesModel
    @ObservedObject var whatsNew: WhatsNewModel
    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(\.intelligence) private var intelligence
    @State private var showsUnchecked = false

    /// A row in either list.
    private enum Entry: Identifiable {
        case available(AppUpdate)
        case recent(RecentUpdate)

        var id: String {
            switch self {
            case let .available(update): "available:" + update.id
            case let .recent(recent): "recent:" + recent.id
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            footer
        }
        .frame(minWidth: Metrics.listMinWidth, maxWidth: .infinity)
        .pageTitle("Updates", shown: false)
        .toolbar { updateAll }
        .focusedSceneValue(\.pageActions, model.installableHere.count > 1 && !model.isInstalling && !model.isChecking
            ? [FocusedAction(name: "Update All") { _ in Task { await model.installAll(service: service) } }] : [])
        .task {
            // The check takes seconds; the model loads meanwhile, so long
            // release notes are read without a second wait.
            async let warm: Void = intelligence?.prewarm(for: .releaseNotes) ?? ()
            await model.load(service: service)
            await warm
        }
    }

    // MARK: - Header

    /// Update All sits in the toolbar beside Check Again once there is
    /// more than one update to install here.
    @ToolbarContentBuilder
    private var updateAll: some ToolbarContent {
        if model.installableHere.count > 1 {
            ToolbarItem(placement: .primaryAction) {
                Button("Update All") { Task { await model.installAll(service: service) } }
                    .disabled(model.isInstalling || model.isChecking)
            }
        }
    }

    // MARK: - Lists

    private var sections: [ItemGroup<Entry>] {
        var sections: [ItemGroup<Entry>] = []
        if let pending = model.pending, !pending.isEmpty {
            sections.append(ItemGroup(id: "available", title: "Available", items: pending.map(Entry.available)))
        }
        if !model.recent.isEmpty {
            sections.append(ItemGroup(id: "recent", title: "Updated recently", items: model.recent.map(Entry.recent)))
        }
        return sections
    }

    @ViewBuilder
    private var content: some View {
        if model.check == nil {
            if model.isChecking {
                SkeletonRows(showsTick: false)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                EmptyState(symbol: "arrow.down.circle", title: "Not checked", message: "Check Again looks for updates.")
            }
        } else if sections.isEmpty {
            if let check = model.check, check.checked == 0, !check.unchecked.isEmpty {
                EmptyState(symbol: "questionmark.circle", title: "Couldn't check for updates",
                           message: "Check Again retries the update sources.")
            } else {
                EmptyState(symbol: "checkmark.circle", title: "0 updates available",
                           message: "Every app Brim checked is up to date.")
            }
        } else {
            if model.pending?.isEmpty == true, let check = model.check {
                upToDate(check)
            }
            GroupedStacks(
                sections: sections,
                summary: { "\($0.items.count)" },
                inspected: nil,
                inspect: { _ in },
                row: row
            )
            .refreshing(model.isChecking)
        }
    }

    /// Nothing pending, said where the pending ones would be, so the page
    /// answers its question before the list of what already happened.
    private func upToDate(_ check: UpdateCheck) -> some View {
        let confirmed = check.checked > 0
        let summary = confirmed ? "Checked apps are up to date" : "No apps could be checked"
        return HStack(spacing: 12) {
            Image(systemName: confirmed ? "checkmark.circle.fill" : "questionmark.circle")
                .font(.title2)
                .foregroundStyle(confirmed ? Palette.success : Palette.inkSecondary)
            // How many were checked is in the line at the foot of the page.
            Text(summary)
                .font(.brimRowTitle)
                .foregroundStyle(Palette.ink)
            Spacer()
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("\(summary), \(check.checked) checked")
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        switch entry {
        case let .available(update):
            UpdateRow(
                url: update.appURL, name: update.name, facts: facts(update), failed: failure(update),
                whatsNew: whatsNew.state(for: update)
            ) {
                action(update)
            }
            .task(id: WhatsNewModel.key(update)) { await whatsNew.read(update, engine: intelligence) }
        case let .recent(recent):
            UpdateRow(url: recent.appURL, name: recent.name, facts: Self.facts(recent), failed: nil) {
                Button("Open") { NSWorkspace.shared.open(recent.appURL) }
                    .capsuleAction()
            }
        }
    }

    private func facts(_ update: AppUpdate) -> String {
        switch model.states[update.id] {
        case let .downloading(progress):
            // Sizes, not a percentage: a 1.3 GB download sat at one figure
            // long enough to look stuck.
            guard progress.expected > 0 else { return "Downloading" }
            return "Downloading \(ByteText.short(progress.received)) of \(ByteText.short(progress.expected))"
        case .installing: return "Installing"
        // A handoff, not an installation: Installer still has to finish.
        case .openedInstaller: return "Finish in Installer"
        // Also set when the app turned out to be current already, so it
        // says where the app is now, not that an update happened.
        case let .updated(version): return "Now \(version)"
        case .failed, .stillOpen: return "Update failed"
        case .notAllowed: return "Needs App Management"
        default:
            let versions = "\(update.installedVersion) → \(update.latestVersion)"
            guard let bytes = update.download?.bytes, bytes > 0 else { return versions }
            return versions + " · " + ByteText.short(bytes)
        }
    }

    static let appManagementSettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!

    /// Why it failed, behind the row's Details button.
    private func failure(_ update: AppUpdate) -> String? {
        switch model.states[update.id] {
        case let .failed(why), let .stillOpen(why): why
        default: nil
        }
    }

    private static func facts(_ recent: RecentUpdate) -> String {
        let versions = recent.fromVersion.map { "\($0) → \(recent.toVersion)" } ?? recent.toVersion
        let calendar = Calendar.current
        let when = calendar.isDateInToday(recent.updatedAt) ? "Today"
            : calendar.isDateInYesterday(recent.updatedAt) ? "Yesterday"
            : day.format(recent.updatedAt)
        return versions + " · " + when
    }

    /// Built once, not for every row each time it draws.
    private static let day = Date.FormatStyle.dateTime.day().month(.abbreviated)

    @ViewBuilder
    private func action(_ update: AppUpdate) -> some View {
        switch model.states[update.id] {
        case let .downloading(progress):
            ProgressView(value: progress.fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .accessibilityLabel("Downloading")
        case .installing:
            ProgressView().controlSize(.small).accessibilityLabel("Installing")
        case .openedInstaller:
            // Opening Installer is the next step, never the result, so it
            // gets no verified mark.
            Image(systemName: "arrow.up.forward.app")
                .foregroundStyle(Palette.inkSecondary)
                .accessibilityLabel("Opened in Installer")
        case .updated:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.success)
                .accessibilityLabel("Updated")
        case .notAllowed:
            Button("Open Settings") {
                open(Self.appManagementSettings)
                model.clearState(of: update)
            }
            .capsuleAction()
        case .failed, .stillOpen:
            HStack(spacing: 6) {
                FailureDetails(reason: failure(update) ?? "")
                Button("Try Again") { Task { await model.install(update, service: service) } }
                    .capsuleAction()
                    .disabled(model.isChecking)
            }
        case nil:
            primaryButton(update)
        }
    }

    @ViewBuilder
    private func primaryButton(_ update: AppUpdate) -> some View {
        switch update.route {
        case .replace, .homebrew, .installer:
            Button("Update") { Task { await model.install(update, service: service) } }
                .capsuleAction()
                .disabled(model.isChecking)
        case .appStore:
            Button("App Store") { open(update.pageURL) }
                .capsuleAction()
                .disabled(update.pageURL == nil)
        case .website:
            Button("Website") { open(update.pageURL ?? update.releaseNotesURL) }
                .capsuleAction()
                .disabled(update.pageURL == nil && update.releaseNotesURL == nil)
        }
    }

    private func open(_ url: URL?) {
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if let check = model.check {
            HStack(spacing: 6) {
                // A minute's refresh, as every "Checked" line has. Formatting
                // the age on each redraw made a download's progress tick it
                // second by second.
                TimelineView(.everyMinute) { context in
                    Text("Checked \(check.checked) \(check.checked == 1 ? "app" : "apps") "
                        + Freshness.age(of: check.checkedAt, now: context.date))
                }
                if !check.unchecked.isEmpty {
                    Text("·")
                    Button("\(check.unchecked.count) can't be checked") { showsUnchecked = true }
                        .buttonStyle(.link)
                        .popover(isPresented: $showsUnchecked, arrowEdge: .top) { unchecked(check.unchecked) }
                }
                Spacer()
            }
            .font(.brimFacts)
            .foregroundStyle(Palette.inkSecondary)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
    }

    private func unchecked(_ apps: [UncheckedApp]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(apps) { app in
                HStack(spacing: 10) {
                    BrimIcon(source: .bundle(app.appURL), size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).font(.brimRowTitle).foregroundStyle(Palette.ink)
                        Text(app.reason).font(.caption).foregroundStyle(Palette.inkSecondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }
}

/// One app in either list: icon, name, one line of facts, one control. A
/// failure is a mark and the word, with the reason behind a Details button
/// a keyboard can reach; it used to be hover help only.
private struct UpdateRow<Action: View>: View {
    let url: URL
    let name: String
    let facts: String
    let failed: String?
    var whatsNew: WhatsNewModel.State?
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 12) {
            BrimIcon(source: .bundle(url))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                HStack(spacing: 4) {
                    if failed != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .imageScale(.small)
                    }
                    Text(facts)
                        .monospacedDigit()
                }
                .font(.brimFacts)
                .foregroundStyle(failed == nil ? Palette.inkSecondary : Palette.caution)
                if let whatsNew {
                    WhatsNewLine(state: whatsNew)
                }
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("\(name), \(facts)" + (failed.map { ", \($0)" } ?? "") + spokenNews)
            Spacer(minLength: 8)
            // A fixed place for the control, so Update, its progress, the
            // result and Retry take turns without moving anything else.
            action()
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .frame(minWidth: 120, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, whatsNew == nil ? 0 : 8)
        .frame(minHeight: Metrics.rowHeight)
    }

    private var spokenNews: String {
        whatsNew.map { WhatsNewLine.spoken($0) } ?? ""
    }
}

/// The reason an update failed, in a popover from a real button.
private struct FailureDetails: View {
    let reason: String
    @State private var shows = false

    var body: some View {
        Button("Details", systemImage: "info.circle") { shows = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.inkSecondary)
            .help(reason)
            .accessibilityLabel("Why the update failed")
            .popover(isPresented: $shows, arrowEdge: .bottom) {
                Text(reason)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(width: 300, alignment: .leading)
            }
    }
}
