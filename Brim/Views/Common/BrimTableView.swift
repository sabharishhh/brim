import SwiftUI
import AppKit

/// One column of a `BrimTableView`.
struct BrimTableColumn<Item: Identifiable & Equatable> {
    var id: String
    var title: String
    var width: CGFloat?
    var minWidth: CGFloat
    var maxWidth: CGFloat?
    /// How this column sorts, when it sorts. Nil means the header is not
    /// clickable, which is right for a column of icons.
    var compare: ((Item, Item) -> Bool)?
    /// What type-select matches against. Typing "fig" should land on
    /// Figma the way it does in Finder.
    var typeSelectText: ((Item) -> String)?
    var cell: (Item) -> AnyView

    init<V: View>(
        id: String,
        title: String,
        width: CGFloat? = nil,
        minWidth: CGFloat = 50,
        maxWidth: CGFloat? = nil,
        compare: ((Item, Item) -> Bool)? = nil,
        typeSelectText: ((Item) -> String)? = nil,
        @ViewBuilder cell: @escaping (Item) -> V
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.compare = compare
        self.typeSelectText = typeSelectText
        self.cell = { AnyView(cell($0)) }
    }
}

/// An `NSTableView` behind a SwiftUI surface, for lists a `List` cannot
/// carry.
///
/// SwiftUI's `List` builds a view per row and keeps them. That is fine at
/// eighty rows and not fine at fourteen hundred, which is what the
/// Background section holds once macOS's own registrations are included.
/// `NSTableView` reuses a handful of views however long the list is, which
/// is the whole reason to drop down to it.
///
/// Three things here exist because of specific failures:
///
/// **The window used to open at half the display width** whatever
/// `.defaultSize` asked for, and clearing every piece of saved state made
/// no difference. A plain `NSScrollView` reports the width of its
/// document view as its intrinsic size, SwiftUI honours that over the
/// scene's request, and a table with a few wide columns therefore decides
/// how big the window is. `NoIntrinsicScrollView` refuses to answer, and
/// that is why this bridge was written, shelved and unused.
///
/// **`reloadData` on every update** threw away scroll position and did a
/// full pass for any unrelated state change, so scrolling a long list
/// stuttered against its own redraws. The rows are reloaded when the rows
/// change, and not otherwise.
///
/// **Sorting, type-select and a context menu** are what makes a table a
/// table rather than a list with lines in it. Column widths are persisted
/// by `NSTableView` itself once it has an autosave name.
struct BrimTableView<Item: Identifiable & Equatable>: NSViewRepresentable {
    var items: [Item]
    var columns: [BrimTableColumn<Item>]
    @Binding var selection: Set<Item.ID>
    /// Distinguishes one table's saved column widths from another's.
    var autosaveName: String
    /// Rows the person right-clicked, and what to offer for them.
    var contextMenu: ((Set<Item.ID>) -> NSMenu?)?
    var onDoubleClick: ((Item) -> Void)?

    init(
        items: [Item],
        columns: [BrimTableColumn<Item>],
        selection: Binding<Set<Item.ID>>,
        autosaveName: String,
        contextMenu: ((Set<Item.ID>) -> NSMenu?)? = nil,
        onDoubleClick: ((Item) -> Void)? = nil
    ) {
        self.items = items
        self.columns = columns
        self._selection = selection
        self.autosaveName = autosaveName
        self.contextMenu = contextMenu
        self.onDoubleClick = onDoubleClick
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NoIntrinsicScrollView()
        scrollView.documentView = context.coordinator.tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.rebuildColumns()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        if coordinator.columns.map(\.id) != columns.map(\.id) {
            coordinator.columns = columns
            coordinator.rebuildColumns()
        }
        coordinator.tableView.autosaveName = autosaveName
        coordinator.tableView.autosaveTableColumns = true

        // Only when the rows actually changed. A reload for every
        // unrelated state change loses the scroll position and makes a
        // long list fight its own redraws.
        let changed = coordinator.items.map(\.id) != items.map(\.id)
            || coordinator.items != items
        coordinator.items = items
        if changed {
            coordinator.applySort()
            coordinator.tableView.reloadData()
        }

        coordinator.updateSelection(selection)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// A scroll view with no opinion about how big it should be.
    ///
    /// Without this the table's content width becomes the window's
    /// minimum and `.defaultSize` is silently ignored.
    final class NoIntrinsicScrollView: NSScrollView {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: BrimTableView
        var items: [Item] = []
        var columns: [BrimTableColumn<Item>] = []
        /// The column being sorted by, and which way.
        private var sortColumn: String?
        private var ascending = true
        /// Guards against the selection binding and the table setting each
        /// other in a loop.
        private var isSyncingSelection = false

        lazy var tableView: NSTableView = {
            let table = NSTableView()
            table.dataSource = self
            table.delegate = self
            table.style = .inset
            table.rowSizeStyle = .medium
            table.usesAlternatingRowBackgroundColors = false
            table.gridStyleMask = []
            table.headerView = NSTableHeaderView()
            table.allowsMultipleSelection = true
            table.allowsColumnReordering = false
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.usesAutomaticRowHeights = false
            table.target = self
            table.doubleAction = #selector(doubleClicked)
            table.menu = NSMenu()
            table.menu?.delegate = self
            return table
        }()

        init(_ parent: BrimTableView) {
            self.parent = parent
            self.items = parent.items
            self.columns = parent.columns
            super.init()
        }

        func rebuildColumns() {
            for column in tableView.tableColumns { tableView.removeTableColumn(column) }
            for column in columns {
                let native = NSTableColumn(
                    identifier: NSUserInterfaceItemIdentifier(column.id)
                )
                native.title = column.title
                native.minWidth = column.minWidth
                if let maximum = column.maxWidth { native.maxWidth = maximum }
                if let width = column.width { native.width = width }
                // A prototype is what makes the header clickable. Columns
                // with no ordering get none, so their headers do nothing
                // rather than sorting by something arbitrary.
                if column.compare != nil {
                    native.sortDescriptorPrototype = NSSortDescriptor(
                        key: column.id, ascending: true
                    )
                }
                tableView.addTableColumn(native)
            }
        }

        func applySort() {
            guard let sortColumn,
                  let column = columns.first(where: { $0.id == sortColumn }),
                  let compare = column.compare
            else { return }
            items.sort { ascending ? compare($0, $1) : compare($1, $0) }
        }

        func updateSelection(_ wanted: Set<Item.ID>) {
            let current = Set(tableView.selectedRowIndexes.compactMap {
                $0 < items.count ? items[$0].id : nil
            })
            guard current != wanted else { return }

            var indexes = IndexSet()
            for (index, item) in items.enumerated() where wanted.contains(item.id) {
                indexes.insert(index)
            }
            isSyncingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isSyncingSelection = false
        }

        @objc private func doubleClicked() {
            let row = tableView.clickedRow
            guard row >= 0, row < items.count else { return }
            parent.onDoubleClick?(items[row])
        }

        // MARK: - Data

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            guard let tableColumn,
                  row < items.count,
                  let column = columns.first(where: { $0.id == tableColumn.identifier.rawValue })
            else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("cell.\(column.id)")
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self)
                as? NSHostingView<AnyView> {
                reused.rootView = column.cell(items[row])
                return reused
            }
            let fresh = NSHostingView(rootView: column.cell(items[row]))
            fresh.identifier = identifier
            return fresh
        }

        /// What typing jumps to, the way Finder does.
        func tableView(
            _ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int
        ) -> String? {
            guard row < items.count else { return nil }
            let searchable = columns.first { $0.typeSelectText != nil }
            return searchable?.typeSelectText?(items[row])
        }

        func tableView(
            _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key
            else { return }
            sortColumn = key
            ascending = descriptor.ascending
            applySort()
            tableView.reloadData()
            updateSelection(parent.selection)
        }

    /// Builds the context menu against the rows the click applies to.
    ///
    /// Right-clicking a row outside the selection acts on that row, which
    /// is what every Mac table does and what a person expects when they
    /// right-click something they have not selected.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = tableView.clickedRow
        var targets = parent.selection
        if clicked >= 0, clicked < items.count, !targets.contains(items[clicked].id) {
            targets = [items[clicked].id]
        }
        guard !targets.isEmpty, let built = parent.contextMenu?(targets) else { return }
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }
    }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection else { return }
            let selected = tableView.selectedRowIndexes.compactMap {
                $0 < items.count ? items[$0].id : nil
            }
            parent.selection = Set(selected)
        }
    }
}
