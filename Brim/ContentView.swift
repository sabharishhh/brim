import SwiftUI

struct ContentView: View {
    @State private var selection: NavigationItem? = .review

    var body: some View {
        NavigationSplitView {
            MainSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            if let selection = selection {
                switch selection {
                case .review:
                    ReviewQueueView(selection: $selection)
                case .applications:
                    ApplicationsView()
                case .history:
                    RemovalHistoryView()
                default:
                    Text("\(selection.rawValue) View")
                        .foregroundColor(.secondary)
                        .font(.title)
                }
            } else {
                Text("Select an item")
                    .foregroundColor(.secondary)
            }
        }
    }
}
