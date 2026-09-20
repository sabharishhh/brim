import SwiftUI
import BrimProtocol
import BrimCore

public struct HistoryListView: View {
    @SwiftUI.Environment(\.brimService) var service
    
    @State private var entries: [Plan] = []
    @State private var selectedEntry: Plan?
    
    public init() {}
    
    public var body: some View {
        NavigationSplitView {
            List(entries, id: \.planId, selection: $selectedEntry) { entry in
                NavigationLink(value: entry) {
                    VStack(alignment: .leading) {
                        Text("Plan \(entry.planId.uuidString.prefix(8))")
                            .font(.headline)
                        Text(entry.createdAt, style: .date)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("History")
            .onAppear(perform: loadHistory)
        } detail: {
            if let entry = selectedEntry {
                HistoryDetailView(entry: entry, onUndo: {
                    loadHistory()
                    selectedEntry = nil
                })
            } else {
                Text("Select a historical run")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func loadHistory() {
        Task {
            do {
                self.entries = try await service.history().sorted(by: { $0.createdAt > $1.createdAt })
            } catch {
                print("Failed to load history: \(error)")
            }
        }
    }
}
