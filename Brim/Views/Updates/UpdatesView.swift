import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// How each application gets its next version, and what is still checking
/// for software that has gone.
///
/// Everything here is read from the disk. A Sparkle feed is a string in an
/// Info.plist, an App Store purchase is a receipt inside the bundle, a
/// Homebrew cask is a directory in the Caskroom. Only Check for Updates
/// asks anything of the network, and only when pressed.
struct UpdatesView: View {
    @ObservedObject var model: UpdatesModel
    @SwiftUI.Environment(\.brimService) private var service

    var body: some View {
        VStack(spacing: 0) {
            header
            content
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
            if model.isLoading || model.isChecking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking")
            }
            Spacer()
            if model.available.contains(where: \.canInstall) {
                Button("Update All") { Task { await model.installAll(service: service) } }
                    .buttonStyle(.bordered)
                    .disabled(!model.installing.isEmpty)
            }
            Button(model.hasChecked ? "Check Again" : "Check for Updates") {
                Task { await model.check(service: service) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isChecking || model.isLoading)
        }
        .buttonBorderShape(.capsule)
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var summary: String {
        if model.isChecking {
            return "Checking"
        }
        // Nothing until the list is read: a zero nobody measured is a lie.
        if model.report.coverage.isEmpty {
            return ""
        }
        if !model.hasChecked {
            let count = model.report.coverage.filter { !$0.sources.isEmpty }.count
            return count == 1 ? "1 app can be checked" : "\(count) apps can be checked"
        }
        let count = model.available.count
        if count == 0 {
            return "Up to date"
        }
        return count == 1 ? "1 update" : "\(count) updates"
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if model.isLoading, model.report.coverage.isEmpty {
            SkeletonRows(showsTick: false)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if sections.isEmpty {
            EmptyState(symbol: "checkmark.seal", title: "Nothing to report", message: "No apps or updaters found.")
        } else {
            VStack(spacing: 0) {
                if let problem = model.problem {
                    Notice(symbol: "exclamationmark.triangle", title: "Could not check", detail: problem)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                }
                GroupedStacks(
                    sections: sections,
                    summary: { "\($0.items.count)" },
                    inspected: nil,
                    inspect: { _ in },
                    row: row
                )
                .refreshing(model.isLoading)
            }
        }
    }

    /// What can be updated first, then what never will be by itself, then
    /// what Homebrew owns, then the updaters themselves.
    private var sections: [ItemGroup<Item>] {
        [
            ItemGroup(
                id: "available", title: "Available",
                items: model.available.map { Item(id: "a:" + $0.id, kind: .available($0)) }
            ),
            ItemGroup(
                id: "casks", title: "Homebrew records with nothing installed",
                items: model.orphanedCasks.map { Item(id: "c:" + $0.id, kind: .orphanedCask($0)) }
            ),
            ItemGroup(
                id: "manual", title: "You update these yourself",
                items: model.stranded.map { Item(id: "m:" + $0.id, kind: .manual($0)) }
            ),
            ItemGroup(
                id: "homebrew", title: "Installed by Homebrew",
                items: model.homebrewManaged.map { Item(id: "h:" + $0.id, kind: .homebrew($0)) }
            ),
            ItemGroup(
                id: "gone", title: "Checking for software that has gone",
                items: model.orphaned.map { Item(id: "g:" + $0.id, kind: .agent($0)) }
            ),
            ItemGroup(
                id: "working", title: "Checking for software you have",
                items: model.working.map { Item(id: "w:" + $0.id, kind: .agent($0)) }, startsCollapsed: true
            )
        ]
        .filter { !$0.items.isEmpty }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 12) {
            BrimIcon(source: icon(item), badge: badge(item))
            VStack(alignment: .leading, spacing: 2) {
                Text(title(item))
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text(facts(item))
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("\(title(item)), \(facts(item))")
            Spacer(minLength: 8)
            action(item)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.rowHeight)
        .rowHighlight(isInspected: false)
    }

    private func title(_ item: Item) -> String {
        switch item.kind {
        case let .available(update): update.name
        case let .orphanedCask(cask): cask.name
        case let .manual(entry), let .homebrew(entry): entry.application.name
        case let .agent(agent): agent.vendor
        }
    }

    private func facts(_ item: Item) -> String {
        switch item.kind {
        case let .available(update): update.installed.map { "\($0) to \(update.latest)" } ?? "Version \(update.latest)"
        case let .orphanedCask(cask): cask.installedVersion.map { "Records version \($0)" } ?? "Nothing installed"
        case let .manual(entry): [entry.application.version, ByteText.short(entry.application.bundleSizeBytes)]
            .compactMap(\.self).joined(separator: " · ")
        case let .homebrew(entry): entry.homebrewCask.map { "Cask \($0)" } ?? "Homebrew cask"
        case let .agent(agent): agent.productIsInstalled ? agent.registration.identifier : "Nothing left to update"
        }
    }

    private func icon(_ item: Item) -> IconSource {
        switch item.kind {
        case let .available(update):
            if IconMemory.standard.has(update.bundleID) {
                .remembered(bundleID: update.bundleID)
            } else {
                .monogram(Monogram(name: update.name))
            }
        case let .orphanedCask(cask): .monogram(Monogram(name: cask.name))
        case let .manual(entry), let .homebrew(entry): .bundle(entry.application.url)
        case .agent: .symbol(.launchAgent)
        }
    }

    private func badge(_ item: Item) -> IconBadge? {
        switch item.kind {
        case .orphanedCask: .removed
        case let .agent(agent): agent.productIsInstalled ? nil : .removed
        default: nil
        }
    }

    @ViewBuilder
    private func action(_ item: Item) -> some View {
        switch item.kind {
        case let .available(update):
            if model.installing.contains(update.bundleID) {
                ProgressView().controlSize(.small)
            } else if update.canInstall {
                Button("Update") { Task { await model.install(update, service: service) } }
            } else if case .appStore = update.source {
                Button("Open App Store") {
                    if let url = URL(string: "macappstore://showUpdatesPage") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                // The app installs its own updates; opening it lets it.
                Button("Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/\(update.name).app"))
                }
                .help("Updates itself when opened")
            }
        case let .orphanedCask(cask):
            Button("Remove Record") { Task { await model.forget(cask, service: service) } }
                .help("Homebrew keeps offering to update software that is not here")
        case let .agent(agent):
            if let program = agent.registration.programPath {
                RowAction(symbol: "arrow.up.forward.app", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: program)])
                }
            }
        case .manual, .homebrew:
            EmptyView()
        }
    }
}

/// One row of the Updates lens, whatever kind of thing it is about.
private struct Item: Identifiable {
    let id: String
    let kind: ItemKind
}

private enum ItemKind {
    case available(AvailableUpdate)
    case orphanedCask(OrphanedCask)
    case manual(UpdateCoverage)
    case homebrew(UpdateCoverage)
    case agent(UpdaterAgent)
}
