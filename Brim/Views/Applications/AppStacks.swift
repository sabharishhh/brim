import BrimCore
import BrimUI
import SwiftUI

/// The Apps list: one section per group, rows on the page under its title,
/// seven then "Show all". A styled `List` so rows are measured once and
/// the section headers pin while scrolling.
struct AppStacks: View {
    @ObservedObject var model: ApplicationsModel
    let groups: [ItemGroup<InstalledApplication>]
    let opened: [String: String]
    let remove: (InstalledApplication) -> Void

    @SwiftUI.Environment(ShellState.self) private var shell
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: Set<String> = []
    @State private var flipped: Set<String> = []

    var body: some View {
        List {
            ForEach(groups) { group in
                Section {
                    if !isCollapsed(group) {
                        ForEach(visibleRows(group)) { app in
                            AppRow(
                                app: app, opened: opened[app.id], isSelected: model.selected?.id == app.id,
                                select: { model.select(app) }, remove: { remove(app) }
                            )
                            .contextMenu { menu(app) }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                            .listRowSeparator(.hidden)
                        }
                        if group.items.count > Metrics.rowsBeforeShowAll {
                            showAll(group)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 6, trailing: 24))
                                .listRowSeparator(.hidden)
                        }
                    }
                } header: {
                    header(group)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .quickLookOnSpace(model.selected.map { [$0.url] } ?? [], shell: shell)
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { move(by: -1) }
    }

    @ViewBuilder
    private func menu(_ app: InstalledApplication) -> some View {
        ItemMenuItems(urls: [app.url])
        Divider()
        Button("Remove \(app.name)…") { remove(app) }
            .disabled(app.isSystemProtected)
    }

    private func header(_ group: ItemGroup<InstalledApplication>) -> some View {
        let bytes = group.items.reduce(0) { $0 + $1.bundleSizeBytes }
        return Button {
            withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
                flipped.formSymmetricDifference([group.id])
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.inkTertiary)
                    .rotationEffect(.degrees(isCollapsed(group) ? 0 : 90))
                Text(group.title)
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
                Text("\(group.items.count) · \(ByteText.short(bytes))")
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .accessibilityLabel("\(group.title), \(group.items.count) apps, \(ByteText.short(bytes))")
        .accessibilityValue(isCollapsed(group) ? "Collapsed" : "Expanded")
    }

    private func showAll(_ group: ItemGroup<InstalledApplication>) -> some View {
        Button {
            withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
                expanded.formSymmetricDifference([group.id])
            }
        } label: {
            Text(expanded.contains(group.id) ? "Show fewer" : "Show all \(group.items.count)")
                .font(.brimFacts.weight(.medium))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 34)
        }
        .buttonStyle(.press)
    }

    private func isCollapsed(_ group: ItemGroup<InstalledApplication>) -> Bool {
        group.startsCollapsed != flipped.contains(group.id)
    }

    private func visibleRows(_ group: ItemGroup<InstalledApplication>) -> [InstalledApplication] {
        expanded.contains(group.id) ? group.items : Array(group.items.prefix(Metrics.rowsBeforeShowAll))
    }

    private func move(by step: Int) -> KeyPress.Result {
        let order = groups.filter { !isCollapsed($0) }.flatMap(visibleRows)
        guard !order.isEmpty else { return .ignored }
        let current = order.firstIndex { $0.id == model.selected?.id }
        model.select(order[current.map { min(max($0 + step, 0), order.count - 1) } ?? 0])
        return .handled
    }
}

/// The same apps as a sortable table, for people who want to compare
/// columns: Finder's list view, in effect.
struct AppTable: View {
    @ObservedObject var model: ApplicationsModel
    let opened: [String: String]
    @State private var order = [KeyPathComparator(\InstalledApplication.name, comparator: .localizedStandard)]

    var body: some View {
        Table(sorted, selection: Binding(
            get: { model.selected?.id },
            set: { id in model.select(model.applications.first { $0.id == id }) }
        ), sortOrder: $order) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { app in
                HStack(spacing: 8) {
                    BrimIcon(source: .bundle(app.url), size: 20)
                    Text(app.name)
                }
            }
            .width(min: 180, ideal: 240)
            TableColumn("Developer", value: \.developerForSorting, comparator: .localizedStandard) { app in
                Text(app.developer ?? "")
            }
            TableColumn("Size", value: \.bundleSizeBytes) { app in
                Text(ByteText.short(app.bundleSizeBytes)).monospacedDigit()
            }
            .width(90)
            TableColumn("Last Opened", value: \.lastOpenedForSorting) { app in
                Text(opened[app.id] ?? "")
            }
            TableColumn("Source", value: \.sourceForSorting) { app in
                Text(app.source?.title ?? "")
            }
            .width(100)
        }
    }

    private var sorted: [InstalledApplication] {
        model.visibleApplications.sorted(using: order)
    }
}

private extension InstalledApplication {
    var developerForSorting: String {
        developer ?? ""
    }

    var lastOpenedForSorting: Date {
        lastOpened ?? .distantPast
    }

    var sourceForSorting: String {
        source?.title ?? ""
    }
}
