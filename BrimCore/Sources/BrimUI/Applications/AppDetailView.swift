import SwiftUI
import AppKit
import BrimProtocol
import BrimCore

public struct AppDetailView: View {
    let appURL: URL
    let appName: String
    let icon: NSImage
    
    @SwiftUI.Environment(\.brimService) var service
    
    @State private var footprint: Footprint?
    @State private var isLoading = false
    @State private var error: String?
    @State private var showingPlanSheet = false
    @State private var generatedPlan: Plan?
    
    public init(appURL: URL, appName: String, icon: NSImage) {
        self.appURL = appURL
        self.appName = appName
        self.icon = icon
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            
            if isLoading {
                ProgressView("Analyzing footprint...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let footprint = footprint {
                footprintView(footprint: footprint)
            } else {
                Text("Ready to analyze.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: appURL) {
            await analyzeApp()
        }
        .sheet(isPresented: $showingPlanSheet) {
            if let plan = generatedPlan, let footprint = footprint {
                PlanSheetView(plan: plan, identity: footprint.identity, isPresented: $showingPlanSheet)
            }
        }
    }
    
    private var headerView: some View {
        HStack(spacing: 16) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 64, height: 64)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(appName)
                    .font(.title)
                if let footprint = footprint {
                    Text("\(footprint.items.count) items found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if footprint != nil {
                Button("Review Plan") {
                    generatePlan()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
    
    private func footprintView(footprint: Footprint) -> some View {
        let grouped = Dictionary(grouping: footprint.items, by: { $0.capability })
        let sortedCaps = grouped.keys.sorted { $0.rawValue < $1.rawValue }
        
        return List {
            ForEach(sortedCaps, id: \.self) { cap in
                let itemsForCap = grouped[cap] ?? []
                Section(header: Text("Capability \(cap.rawValue)").font(.headline)) {
                    ForEach(itemsForCap, id: \.evidence.url.path) { item in
                        let path = item.evidence.url.path
                        VStack(alignment: .leading, spacing: 4) {
                            Text(path)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            
                            Text(item.evidence.humanSentence)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
    
    private func analyzeApp() async {
        isLoading = true
        error = nil
        do {
            // Need to resolve Identity first
            // We use a dummy IdentityResolver with a dummy root for the real app,
            // but we can just construct an Identity if we parse Info.plist, or just use the bundle URL directly.
            // Wait, we need an Identity to pass to inspect().
            // Identity requires bundleIdentifier.
            let bundle = Bundle(url: appURL)
            let bundleId = bundle?.bundleIdentifier ?? "unknown"
            
            let id = Identity(
                bundleID: bundleId,
                teamID: nil,
                name: bundle?.infoDictionary?["CFBundleName"] as? String ?? appName,
                version: bundle?.infoDictionary?["CFBundleShortVersionString"] as? String,
                isSandboxed: false,
                groupContainers: []
            )
            
            self.footprint = try await service.inspect(identity: id)
        } catch {
            self.error = "Analysis failed: \(error.localizedDescription)"
        }
        isLoading = false
    }
    
    private func generatePlan() {
        Task {
            guard let footprint = footprint else { return }
            do {
                let intent = PlanIntent(type: .uninstall, subjectIdentity: footprint.identity)
                self.generatedPlan = try await service.plan(intent: intent)
                self.showingPlanSheet = true
            } catch {
                self.error = "Failed to generate plan: \(error.localizedDescription)"
            }
        }
    }
}
