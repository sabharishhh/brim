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
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inspectedID: String?
    @State private var showsUnchecked = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                content
                footer
            }
            .frame(minWidth: Metrics.listMinWidth, maxWidth: .infinity)
            inspector
                .frame(width: 340)
        }
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

    // MARK: - List

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
        } else if let updates = model.check?.updates, !updates.isEmpty {
            GroupedStacks(
                sections: [ItemGroup(id: "updates", title: "Available", items: updates)],
                summary: { _ in "\(model.count ?? 0)" },
                inspected: inspectedID,
                inspect: { update in
                    withAnimation(Motion.resolved(Motion.inspector, reduceMotion: reduceMotion)) {
                        inspectedID = update.id
                    }
                },
                row: row
            )
            .refreshing(model.isChecking)
        } else {
            EmptyState(symbol: "checkmark.circle", title: "0 updates available",
                       message: "Every app Brim checked is up to date.")
        }
    }

    private func row(_ update: AppUpdate) -> some View {
        HStack(spacing: 12) {
            BrimIcon(source: .bundle(update.appURL))
            VStack(alignment: .leading, spacing: 2) {
                Text(update.name)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text(facts(update))
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(isFailed(update) ? Palette.caution : Palette.inkSecondary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("\(update.name), \(facts(update))")
            Spacer(minLength: 8)
            action(update)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.rowHeight)
        .rowHighlight(isInspected: inspectedID == update.id)
        .contentShape(.rect)
    }

    private func facts(_ update: AppUpdate) -> String {
        switch model.states[update.id] {
        case .downloading(let fraction): return "Downloading \(Int(fraction * 100))%"
        case .installing: return "Installing"
        case .updated(let version): return "Updated to \(version)"
        case .openedInstaller: return "Opened in Installer"
        case .stillOpen(let name): return "Quit \(name) to update"
        case .failed(let why): return why
        case nil:
            let versions = "\(update.installedVersion) → \(update.latestVersion)"
            guard let bytes = update.download?.bytes, bytes > 0 else { return versions }
            return versions + " · " + ByteText.short(bytes)
        }
    }

    private func isFailed(_ update: AppUpdate) -> Bool {
        switch model.states[update.id] {
        case .failed, .stillOpen: return true
        default: return false
        }
    }

    @ViewBuilder
    private func action(_ update: AppUpdate) -> some View {
        switch model.states[update.id] {
        case .downloading(let fraction):
            ProgressView(value: fraction)
                .frame(width: 60)
                .accessibilityLabel("Downloading")
        case .installing:
            ProgressView().controlSize(.small).accessibilityLabel("Installing")
        case .updated, .openedInstaller:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.inkSecondary)
                .accessibilityLabel("Done")
        case .stillOpen, .failed:
            Button("Try Again") { Task { await model.install(update, service: service) } }
                .buttonStyle(.bordered)
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
        if let url { NSWorkspace.shared.open(url) }
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

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let update = model.check?.updates.first(where: { $0.id == inspectedID }) {
            UpdateInspector(update: update, state: model.states[update.id]) {
                primaryButton(update).buttonBorderShape(.capsule)
            }
            .id(update.id)
            .transition(.opacity)
        } else {
            PanePlaceholder(symbol: "arrow.down.circle", title: "Select an update")
        }
    }
}

/// One update in full: what changes, where the version came from, and how
/// it will be put in place.
private struct UpdateInspector<Action: View>: View {
    let update: AppUpdate
    let state: UpdatesModel.InstallState?
    @ViewBuilder let action: () -> Action

    var body: some View {
        List {
            Group {
                VStack(alignment: .leading, spacing: 10) {
                    BrimIcon(source: .bundle(update.appURL), size: 64)
                    Text(update.name)
                        .font(.brimPageTitle)
                        .foregroundStyle(Palette.ink)
                    Text("\(update.installedVersion) → \(update.latestVersion)")
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                    if state == nil { action() }
                    if case .failed(let why) = state {
                        Text(why)
                            .font(.brimFacts)
                            .foregroundStyle(Palette.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                fact("Source", update.origin.title)
                if let date = update.releasedAt {
                    fact("Released", date.formatted(date: .abbreviated, time: .omitted))
                }
                if let bytes = update.download?.bytes, bytes > 0 {
                    fact("Download", ByteText.short(bytes))
                }
                fact("How it installs", update.route.explanation)
                if let notes = update.releaseNotes, !notes.isEmpty {
                    fact("What's new", notes)
                } else if let link = update.releaseNotesURL ?? update.pageURL {
                    Link("Release notes", destination: link)
                        .font(.brimFacts)
                }
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.brimGroupTitle)
                .foregroundStyle(Palette.ink)
            Text(value)
                .font(.brimFacts)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.top, 6)
    }
}
