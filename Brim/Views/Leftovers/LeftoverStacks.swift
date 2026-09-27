import BrimCore
import BrimUI
import SwiftUI

/// The Leftovers stacks: one card per group, up to seven rows, then "Show
/// all". A styled `List` rather than a stack in a scroll view, so rows are
/// measured once and reused and the section headers pin while scrolling.
struct LeftoverStacks: View {
    @ObservedObject var model: LeftoversModel
    let grouping: LeftoverGrouping
    let keptIDs: Set<String>
    let newItems: Set<String>
    let pick: (LeftoverGroup) -> Void
    let keep: (LeftoverGroup) -> Void
    /// Makes a change of what is picked one undoable step.
    let changePick: (String, () -> Void) -> Void

    @SwiftUI.Environment(ShellState.self) private var shell
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Cards showing every row rather than the first seven.
    @State private var expanded: Set<String> = []
    /// Cards whose open or closed state the person flipped from the default.
    @State private var flipped: Set<String> = []

    var body: some View {
        stacks
    }

    private var inspectedURLs: [URL] {
        model.inspected?.items.map(\.url) ?? []
    }

    private var sections: [ItemGroup<LeftoverGroup>] {
        LeftoverGrouper().groups(
            model.visibleOrphanedGroups + model.visibleUnclaimedGroups, by: grouping,
            isKept: { keptIDs.contains($0.id) }
        )
    }

    private var stacks: some View {
        let sections = sections
        let new = newItems
        return List {
            ForEach(sections) { section in
                Section {
                    if !isCollapsed(section) {
                        // On the page under their title, not in a box: the
                        // title and the indent already say what belongs
                        // together.
                        ForEach(visibleRows(section)) { group in
                            row(group, new: new)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                                .listRowSeparator(.hidden)
                                .transition(.brimRow(reduceMotion: reduceMotion))
                        }
                        if hasMore(section) {
                            showAll(section)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 6, trailing: 24))
                                .listRowSeparator(.hidden)
                        }
                    }
                } header: {
                    sectionHeader(section)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .quickLookOnSpace(inspectedURLs, shell: shell)
        .onKeyPress(.downArrow) { moveInspection(by: 1, in: sections) }
        .onKeyPress(.upArrow) { moveInspection(by: -1, in: sections) }
        // Rows leaving and arriving are worth seeing: keyed to a counter
        // the model bumps for a removal, a restore or a rescan, and never
        // for a tick, a keystroke in the search field or a scroll.
        .animation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion), value: model.revision)
    }

    private func row(_ group: LeftoverGroup, new: Set<String>) -> some View {
        LeftoverRow(
            group: group,
            isPicked: model.isSelected(group),
            isInspected: model.inspected?.id == group.id,
            isKept: keptIDs.contains(group.id),
            isNew: group.items.contains { new.contains($0.id) },
            pick: { pick(group) },
            inspect: { model.inspected = group },
            keep: { keep(group) }
        )
        .contextMenu {
            ItemMenuItems(urls: group.items.map(\.url))
            Divider()
            Button(model.isSelected(group) ? "Remove from Tray" : "Add to Tray") { pick(group) }
                .disabled(!group.isFullyActionable || keptIDs.contains(group.id))
            Button(keptIDs.contains(group.id) ? "Stop Keeping" : "Keep") { keep(group) }
        }
    }

    private func sectionHeader(_ section: ItemGroup<LeftoverGroup>) -> some View {
        let bytes = section.items.reduce(0) { $0 + $1.totalBytes }
        let pickable = section.items.filter { $0.isFullyActionable && !keptIDs.contains($0.id) }
        return HStack(spacing: 8) {
            Button {
                withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
                    flipped.formSymmetricDifference([section.id])
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.inkTertiary)
                        .rotationEffect(.degrees(isCollapsed(section) ? 0 : 90))
                    Text(section.title)
                        .font(.brimGroupTitle)
                        .foregroundStyle(Palette.ink)
                    Text("\(section.items.count) · \(ByteText.short(bytes))")
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(section.title), \(section.items.count), \(ByteText.short(bytes))")
            .accessibilityValue(isCollapsed(section) ? "Collapsed" : "Expanded")
            Spacer()
            if !pickable.isEmpty {
                let allPicked = pickable.allSatisfy(model.isSelected)
                Button(allPicked ? "Deselect All" : "Select All") {
                    changePick(allPicked ? "Deselect All" : "Select All") {
                        if allPicked {
                            model.deselectAll(groups: pickable)
                        } else {
                            model.selectAll(groups: pickable)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .font(.brimFacts)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func showAll(_ section: ItemGroup<LeftoverGroup>) -> some View {
        Button {
            withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
                expanded.formSymmetricDifference([section.id])
            }
        } label: {
            Text(expanded.contains(section.id) ? "Show fewer" : "Show all \(section.items.count)")
                .font(.brimFacts.weight(.medium))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 34)
        }
        .buttonStyle(.press)
    }

    private func isCollapsed(_ section: ItemGroup<LeftoverGroup>) -> Bool {
        section.startsCollapsed != flipped.contains(section.id)
    }

    private func hasMore(_ section: ItemGroup<LeftoverGroup>) -> Bool {
        section.items.count > Metrics.rowsBeforeShowAll
    }

    private func visibleRows(_ section: ItemGroup<LeftoverGroup>) -> [LeftoverGroup] {
        expanded.contains(section.id) ? section.items : Array(section.items.prefix(Metrics.rowsBeforeShowAll))
    }

    /// Arrow keys move the inspector through the rows that are showing.
    private func moveInspection(by step: Int, in sections: [ItemGroup<LeftoverGroup>]) -> KeyPress.Result {
        let order = sections.filter { !isCollapsed($0) }.flatMap(visibleRows)
        guard !order.isEmpty else { return .ignored }
        let current = order.firstIndex { $0.id == model.inspected?.id }
        let next = current.map { min(max($0 + step, 0), order.count - 1) } ?? 0
        model.inspected = order[next]
        return .handled
    }
}
