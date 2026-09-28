import BrimUI
import SwiftUI

/// A collection as titled groups on the page: a header that folds, up to
/// seven rows, then "Show all".
///
/// A styled `List` rather than a stack in a scroll view, so rows are
/// measured once and reused (`CLAUDE.md`). No box behind a group: the
/// title and the indent already say what belongs together. Leftovers has
/// its own copy of this with ticks and keeps on the header; this one is
/// for the pages that need less.
struct GroupedStacks<Item: Identifiable, Row: View, Accessory: View>: View {
    let sections: [ItemGroup<Item>]
    /// "3 · 1.2 GB" beside a group's title.
    let summary: (ItemGroup<Item>) -> String
    /// Bumped by the model when rows arrive or leave, which is what animates.
    var revision = 0
    let inspected: Item.ID?
    let inspect: (Item) -> Void
    @ViewBuilder let row: (Item) -> Row
    /// Trailing the header: Select All, where a group has anything to pick.
    @ViewBuilder let accessory: (ItemGroup<Item>) -> Accessory

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: Set<String> = []
    /// Groups whose open or closed state the person flipped from the default.
    @State private var flipped: Set<String> = []

    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    if !isCollapsed(section) {
                        ForEach(visibleRows(section)) { item in
                            row(item)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                                .listRowSeparator(.hidden)
                                .transition(.brimRow(reduceMotion: reduceMotion))
                        }
                        if section.items.count > Metrics.rowsBeforeShowAll {
                            showAll(section)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 6, trailing: 24))
                                .listRowSeparator(.hidden)
                        }
                    }
                } header: {
                    header(section)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { move(by: -1) }
        .animation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion), value: revision)
    }

    private func header(_ section: ItemGroup<Item>) -> some View {
        HStack(spacing: 8) {
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
                    Text(summary(section))
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(section.title), \(summary(section))")
            .accessibilityValue(isCollapsed(section) ? "Collapsed" : "Expanded")
            Spacer()
            accessory(section)
                .buttonStyle(.borderless)
                .font(.brimFacts)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func showAll(_ section: ItemGroup<Item>) -> some View {
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

    private func isCollapsed(_ section: ItemGroup<Item>) -> Bool {
        section.startsCollapsed != flipped.contains(section.id)
    }

    private func visibleRows(_ section: ItemGroup<Item>) -> [Item] {
        expanded.contains(section.id) ? section.items : Array(section.items.prefix(Metrics.rowsBeforeShowAll))
    }

    /// Arrow keys move the inspector through the rows that are showing.
    private func move(by step: Int) -> KeyPress.Result {
        let order = sections.filter { !isCollapsed($0) }.flatMap(visibleRows)
        guard !order.isEmpty else { return .ignored }
        let current = order.firstIndex { $0.id == inspected }
        let next = current.map { min(max($0 + step, 0), order.count - 1) } ?? 0
        inspect(order[next])
        return .handled
    }
}

extension GroupedStacks where Accessory == EmptyView {
    init(
        sections: [ItemGroup<Item>], summary: @escaping (ItemGroup<Item>) -> String, revision: Int = 0,
        inspected: Item.ID?, inspect: @escaping (Item) -> Void, @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.init(
            sections: sections, summary: summary, revision: revision, inspected: inspected, inspect: inspect,
            row: row, accessory: { _ in EmptyView() }
        )
    }
}

/// A row's hover and selection wash, shared by every page's rows.
struct RowHighlight: ViewModifier {
    let isInspected: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(fill, in: .rect(cornerRadius: Metrics.rowRadius, style: .continuous))
            .contentShape(.rect)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
            }
            .environment(\.isRowHovered, isHovering)
    }

    private var fill: AnyShapeStyle {
        if isInspected {
            return AnyShapeStyle(.tint.opacity(0.10))
        }
        return AnyShapeStyle(isHovering ? Palette.well : Color.clear)
    }
}

extension EnvironmentValues {
    /// Whether the row this view sits in is under the pointer, so its
    /// actions can appear without each keeping its own hover state.
    @Entry var isRowHovered = false
}

extension View {
    func rowHighlight(isInspected: Bool) -> some View {
        modifier(RowHighlight(isInspected: isInspected))
    }
}

/// Row actions that show only while the pointer is over the row.
struct HoverActions<Content: View>: View {
    @ViewBuilder let content: Content
    @SwiftUI.Environment(\.isRowHovered) private var isHovering

    var body: some View {
        HStack(spacing: 6) { content }
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)
    }
}
