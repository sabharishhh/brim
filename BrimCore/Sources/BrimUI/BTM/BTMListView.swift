import SwiftUI
import BrimCore
import BrimProtocol
import BrimScan

@MainActor
public class BTMListViewModel: ObservableObject {
    @Published public var records: [BTMEnrichedRecord] = []
    @Published public var isLoading = false
    
    public init() {}
    
    public func load(fixture: String? = nil) async {
        isLoading = true
        defer { isLoading = false }
        
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        let scanner = BTMScanner(root: root)
        do {
            if let fixture = fixture {
                self.records = try await scanner.scan(dump: fixture)
            } else {
                // Not running real dumpbtm yet in UI for safety unless implemented
                self.records = try await scanner.scan(dump: "") 
            }
        } catch {
            print("Failed to load BTM records: \(error)")
        }
    }
}

public struct BTMListView: View {
    @StateObject private var viewModel = BTMListViewModel()
    
    public init() {}
    
    public var body: some View {
        VStack {
            if viewModel.isLoading {
                ProgressView()
            } else {
                List(viewModel.records, id: \.record.uuid) { enriched in
                    VStack(alignment: .leading) {
                        Text(enriched.identity?.name ?? enriched.record.name ?? "Unknown")
                            .font(.headline)
                        if let bundleID = enriched.identity?.bundleID ?? enriched.record.bundleIdentifier {
                            Text(bundleID).font(.caption).foregroundColor(.secondary)
                        }
                        Text("UUID: \(enriched.record.uuid)")
                            .font(.caption2)
                            .foregroundColor(.gray)
                        Text("Type: \(enriched.record.type ?? "Unknown")")
                            .font(.caption2)
                        if let url = enriched.record.url {
                            Text("Path: \(url.path)")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                    }
                    .contextMenu {
                        if let url = enriched.record.url {
                            Button("Remove backing file") {
                                removeBackingFile(url: url)
                            }
                        }
                    }
                }
            }
        }
        .task {
            // Load dummy dumpbtm for acceptance
            let dummy = "BTM Dump\n==================\nUser background task manager:\n    Background task:\n        UUID: 12345678-1234-1234-1234-123456789012\n        Name: com.test.Daemon\n        Type: agent\n        URL: file:///Library/LaunchAgents/com.test.Daemon.plist"
            await viewModel.load(fixture: dummy)
        }
    }
    
    private func removeBackingFile(url: URL) {
        let intent = PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: nil, name: "Orphaned File"), specificTarget: url)
        Task {
            do {
                _ = try await BrimClient.shared.plan(intent: intent)
                print("Requested remove for: \(url.path) - Plan generated.")
            } catch {
                print("Failed to plan removal: \(error)")
            }
        }
    }
}
