import SwiftUI
import BrimProtocol
import BrimCore

public struct MainSplitView: View {
    @State private var selection: NavigationItem? = .applications
    
    public init() {}

    public enum NavigationItem {
        case applications
        case history
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                NavigationLink(value: NavigationItem.applications) {
                    Label("Applications", systemImage: "app.badge")
                }
                NavigationLink(value: NavigationItem.history) {
                    Label("History", systemImage: "clock")
                }
            }
            .navigationTitle("Brim")
            .listStyle(.sidebar)
        } detail: {
            switch selection {
            case .applications:
                AppListView()
            case .history:
                HistoryListView()
            case nil:
                Text("Select an item from the sidebar")
                    .foregroundColor(.secondary)
            }
        }
    }
}
