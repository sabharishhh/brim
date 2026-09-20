import SwiftUI
import AppKit

public struct BrimTableColumn<Item: Identifiable & Equatable> {
    public var id: String
    public var title: String
    public var width: CGFloat?
    public var minWidth: CGFloat
    public var maxWidth: CGFloat?
    public var sortDescriptor: NSSortDescriptor?
    public var cell: (Item) -> AnyView
    
    public init<V: View>(
        id: String,
        title: String,
        width: CGFloat? = nil,
        minWidth: CGFloat = 50,
        maxWidth: CGFloat? = nil,
        sortDescriptor: NSSortDescriptor? = nil,
        @ViewBuilder cell: @escaping (Item) -> V
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.sortDescriptor = sortDescriptor
        self.cell = { AnyView(cell($0)) }
    }
}

public struct BrimTableView<Item: Identifiable & Equatable>: NSViewRepresentable {
    public var items: [Item]
    public var columns: [BrimTableColumn<Item>]
    @Binding public var selection: Set<Item.ID>
    
    public init(items: [Item], columns: [BrimTableColumn<Item>], selection: Binding<Set<Item.ID>>) {
        self.items = items
        self.columns = columns
        self._selection = selection
    }
    
    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = context.coordinator.tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }
    
    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        
        // Update columns if they changed
        if coordinator.columns.map(\.id) != columns.map(\.id) {
            coordinator.columns = columns
            coordinator.rebuildColumns()
        }
        
        // Update items without Diffable to ensure O(1) memory footprint for 100k items.
        // NSTableView natively supports just reloading data. 
        coordinator.items = items
        coordinator.tableView.reloadData()
        
        // Sync selection
        coordinator.updateSelection(selection)
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: BrimTableView
        var items: [Item] = []
        var columns: [BrimTableColumn<Item>] = []
        
        lazy var tableView: NSTableView = {
            let tv = NSTableView()
            tv.dataSource = self
            tv.delegate = self
            tv.style = .fullWidth
            tv.rowSizeStyle = .medium
            tv.usesAlternatingRowBackgroundColors = false
            tv.gridStyleMask = [] // Minimalist: no grid lines
            tv.headerView = NSTableHeaderView()
            tv.allowsMultipleSelection = true
            tv.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            return tv
        }()
        
        init(_ parent: BrimTableView) {
            self.parent = parent
            super.init()
        }
        
        func rebuildColumns() {
            // Remove existing
            for col in tableView.tableColumns {
                tableView.removeTableColumn(col)
            }
            
            // Add new
            for column in columns {
                let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
                tc.title = column.title
                if let min = column.minWidth as CGFloat? { tc.minWidth = min }
                if let max = column.maxWidth as CGFloat? { tc.maxWidth = max }
                if let w = column.width as CGFloat? { tc.width = w }
                tc.sortDescriptorPrototype = column.sortDescriptor
                tableView.addTableColumn(tc)
            }
        }
        
        func updateSelection(_ newSelection: Set<Item.ID>) {
            let currentSelectionIds = Set(tableView.selectedRowIndexes.compactMap {
                $0 < items.count ? items[$0].id : nil
            })
            
            guard currentSelectionIds != newSelection else { return }
            
            let indexes = NSMutableIndexSet()
            for (index, item) in items.enumerated() {
                if newSelection.contains(item.id) {
                    indexes.add(index)
                }
            }
            
            tableView.selectRowIndexes(indexes as IndexSet, byExtendingSelection: false)
        }
        
        // MARK: - NSTableViewDataSource
        public func numberOfRows(in tableView: NSTableView) -> Int {
            return items.count
        }
        
        // MARK: - NSTableViewDelegate
        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn = tableColumn,
                  let colIndex = columns.firstIndex(where: { $0.id == tableColumn.identifier.rawValue }) else { return nil }
            
            let item = items[row]
            let columnDef = columns[colIndex]
            
            let cellID = NSUserInterfaceItemIdentifier("Cell_\(columnDef.id)")
            
            var view = tableView.makeView(withIdentifier: cellID, owner: self) as? NSHostingView<AnyView>
            if view == nil {
                view = NSHostingView(rootView: columnDef.cell(item))
                view?.identifier = cellID
            } else {
                view?.rootView = columnDef.cell(item)
            }
            
            return view
        }
        
        public func tableViewSelectionDidChange(_ notification: Notification) {
            let selectedIds = tableView.selectedRowIndexes.compactMap {
                $0 < items.count ? items[$0].id : nil
            }
            parent.selection = Set(selectedIds)
        }
    }
}
