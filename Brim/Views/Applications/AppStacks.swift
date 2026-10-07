import AppKit
import BrimCore
import BrimUI
import SwiftUI

/// The Apps list: one section per group, seven rows then "Show all",
/// drawn by `GroupedStacks` like every other grouped page. It was a copy of
/// that view with the same header, folding, Show All and arrow keys, which
/// is two places to fix each of them.
struct AppStacks: View {
    @ObservedObject var model: ApplicationsModel
    let groups: [ItemGroup<InstalledApplication>]
    let opened: [String: String]
    let remove: (InstalledApplication) -> Void

    @SwiftUI.Environment(ShellState.self) private var shell
    /// Where each row was when the page opened, so nothing reorders under
    /// the pointer while it is open (`StableOrder`).
    @State private var remembered: [String: Int] = [:]

    var body: some View {
        GroupedStacks(
            sections: StableOrder.apply(groups, remembered: remembered),
            summary: { group in
                "\(group.items.count) · \(ByteText.short(group.items.reduce(0) { $0 + $1.bundleSizeBytes }))"
            },
            inspected: model.selected?.id,
            inspect: { model.select($0) },
            row: { app in row(app) }
        )
        .onAppear { remembered = StableOrder.positions(groups) }
        .quickLookOnSpace(model.selected.map { [$0.url] } ?? [], shell: shell)
    }

    private func row(_ app: InstalledApplication) -> some View {
        AppRow(
            app: app, opened: opened[app.id],
            isSelected: model.marked.isEmpty && !model.isChoosing
                ? model.selected?.id == app.id : model.isMarked(app),
            select: { model.select(app) },
            // Command-click marks several for one review, as in Finder.
            mark: { model.isChoosing ? model.toggleChoice(app) : model.toggleMark(app) },
            isChoosing: model.isChoosing
        )
        .contextMenu { menu(app) }
    }

    @ViewBuilder
    private func menu(_ app: InstalledApplication) -> some View {
        ItemMenuItems(urls: [app.url])
        Divider()
        Button("Remove") { remove(app) }
            .disabled(app.isSystemProtected)
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
            get: {
                model.marked.isEmpty && !model.isChoosing
                    ? Set([model.selected?.id].compactMap(\.self)) : Set(model.marked.map(\.id))
            },
            set: { ids in choose(ids) }
        ), sortOrder: $order) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { app in
                HStack(spacing: 8) {
                    if model.isChoosing {
                        Image(systemName: model.isMarked(app) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model
                                .isMarked(app) ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.inkTertiary))
                            .opacity(app.isSystemProtected ? 0.35 : 1)
                            .accessibilityHidden(true)
                    }
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
        // The page's own background, not the table's white and grey bands.
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .padding(.bottom, Metrics.pagePadding)
    }

    /// A plain click on a row. Outside choosing it opens that app, even one
    /// of several selected. While choosing it ticks or unticks the row, the
    /// way the list does; Shift and Command extend as they always have.
    private func choose(_ ids: Set<String>) {
        let rows = sorted.filter { ids.contains($0.id) }
        guard model.isChoosing else { return model.mark(rows) }
        if rows.count == 1, let row = rows.first {
            model.toggleChoice(row)
        } else if rows.count > 1 {
            model.mark(rows)
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
