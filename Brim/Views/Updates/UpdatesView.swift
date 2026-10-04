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
    @SwiftUI.Environment(\.brimService) private var service
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
            header
            content
            footer
        }
        .frame(minWidth: Metrics.listMinWidth, maxWidth: .infinity)
        .task { await model.loadIfNeeded(service: service) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Updates")
                .font(.brimPageTitle)
                .foregroundStyle(Palette.ink)
            Text(summary)
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkSecondary)
            if model.isChecking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking")
            }
            Spacer()
            if model.installableHere.count > 1 {
                Button("Update All") { Task { await model.installAll(service: service) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInstalling || model.isChecking)
            }
        }
        .buttonBorderShape(.capsule)
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var summary: String {
        guard let count = model.count else { return model.isChecking ? "Checking" : "" }
        return count == 1 ? "1 update available" : "\(count) updates available"
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
            EmptyState(symbol: "checkmark.circle", title: "0 updates available",
                       message: "Every app Brim checked is up to date.")
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
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("All apps are up to date")
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text("\(check.checked) \(check.checked == 1 ? "app" : "apps") checked")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("All apps are up to date, \(check.checked) checked")
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        switch entry {
        case let .available(update):
            UpdateRow(url: update.appURL, name: update.name, facts: facts(update), failed: failure(update)) {
                action(update)
            }
        case let .recent(recent):
            UpdateRow(url: recent.appURL, name: recent.name, facts: Self.facts(recent), failed: nil) {
                Button("Open") { NSWorkspace.shared.open(recent.appURL) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func facts(_ update: AppUpdate) -> String {
        switch model.states[update.id] {
        case let .downloading(fraction): return "Downloading \(Int(fraction * 100))%"
        case .installing: return "Installing"
        case .openedInstaller: return "Opened in Installer"
        case .failed: return "Failed"
        case .notAllowed: return "Needs App Management"
        default:
            let versions = "\(update.installedVersion) → \(update.latestVersion)"
            guard let bytes = update.download?.bytes, bytes > 0 else { return versions }
            return versions + " · " + ByteText.short(bytes)
        }
    }

    static let appManagementSettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!

    /// Why it failed, for the pointer to find. The row itself only says so.
    private func failure(_ update: AppUpdate) -> String? {
        if case let .failed(why) = model.states[update.id] {
            return why
        }
        return nil
    }

    private static func facts(_ recent: RecentUpdate) -> String {
        let versions = recent.fromVersion.map { "\($0) → \(recent.toVersion)" } ?? recent.toVersion
        let calendar = Calendar.current
        let when = calendar.isDateInToday(recent.updatedAt) ? "Today"
            : calendar.isDateInYesterday(recent.updatedAt) ? "Yesterday"
            : recent.updatedAt.formatted(.dateTime.day().month(.abbreviated))
        return versions + " · " + when
    }

    @ViewBuilder
    private func action(_ update: AppUpdate) -> some View {
        switch model.states[update.id] {
        case let .downloading(fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .accessibilityLabel("Downloading")
        case .installing:
            ProgressView().controlSize(.small).accessibilityLabel("Installing")
        case .openedInstaller, .updated:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.inkSecondary)
                .accessibilityLabel("Done")
        case .notAllowed:
            Button("Open Settings") {
                open(Self.appManagementSettings)
                model.clearState(of: update)
            }
            .buttonStyle(.bordered)
        case .failed, .stillOpen:
            Button("Retry") { Task { await model.install(update, service: service) } }
                .buttonStyle(.bordered)
                .disabled(model.isChecking)
        case nil:
            primaryButton(update)
        }
    }

    @ViewBuilder
    private func primaryButton(_ update: AppUpdate) -> some View {
        switch update.route {
        case .replace, .homebrew, .installer:
            Button("Update") { Task { await model.install(update, service: service) } }
                .buttonStyle(.bordered)
                .disabled(model.isChecking)
        case .appStore:
            Button("App Store") { open(update.pageURL) }
                .buttonStyle(.bordered)
                .disabled(update.pageURL == nil)
        case .website:
            Button("Website") { open(update.pageURL ?? update.releaseNotesURL) }
                .buttonStyle(.bordered)
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
                Text("Checked \(check.checked) \(check.checked == 1 ? "app" : "apps") "
                    + check.checkedAt.formatted(.relative(presentation: .named)))
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
/// failure is a mark and the word, with the reason on the pointer for the
/// few who want it.
private struct UpdateRow<Action: View>: View {
    let url: URL
    let name: String
    let facts: String
    let failed: String?
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
            }
            .lineLimit(1)
            .help(failed ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("\(name), \(facts)" + (failed.map { ", \($0)" } ?? ""))
            Spacer(minLength: 8)
            action()
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.rowHeight)
    }
}
