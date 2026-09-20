import SwiftUI
import AppKit

public struct InstalledApp: Identifiable, Hashable {
    public let id: URL
    public let name: String
    public let icon: NSImage
    
    public init(url: URL) {
        self.id = url
        self.name = url.deletingPathExtension().lastPathComponent
        self.icon = NSWorkspace.shared.icon(forFile: url.path)
    }
}

public struct AppListView: View {
    @State private var apps: [InstalledApp] = []
    @State private var selectedApp: InstalledApp?
    
    public init() {}
    
    public var body: some View {
        NavigationSplitView {
            List(apps, selection: $selectedApp) { app in
                NavigationLink(value: app) {
                    HStack {
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: 32, height: 32)
                        Text(app.name)
                            .font(.body)
                    }
                }
            }
            .navigationTitle("Applications")
            .onAppear(perform: loadApps)
        } detail: {
            if let selectedApp = selectedApp {
                AppDetailView(appURL: selectedApp.id, appName: selectedApp.name, icon: selectedApp.icon)
            } else {
                Text("Select an application")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func loadApps() {
        // Just scan /Applications non-recursively for now to get a list.
        let applicationsURL = URL(fileURLWithPath: "/Applications")
        guard let urls = try? FileManager.default.contentsOfDirectory(at: applicationsURL, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else {
            return
        }
        
        var foundApps: [InstalledApp] = []
        for url in urls where url.pathExtension == "app" {
            foundApps.append(InstalledApp(url: url))
        }
        
        self.apps = foundApps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
