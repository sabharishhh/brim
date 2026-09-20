import Foundation
import SwiftUI
import BrimProtocol
import BrimCore
import BrimUI

@main struct BrimAppMain: App {
    @FocusedValue(\.removeSelectedAction) var removeSelectedAction
    
    let client: any BrimServiceProtocol = BrimServiceLocator.makeService()
    
    @State private var showSelfUninstall = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.brimService, client)
                .alert("Uninstall Brim?", isPresented: $showSelfUninstall) {
                    Button("Cancel", role: .cancel) {}
                    Button("Uninstall", role: .destructive) {
                        Task { await performSelfUninstall() }
                    }
                } message: {
                    Text("This will remove the Brim application, its privileged helper, background agents, and all related data.")
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandMenu("Action") {
                Button("Remove Selected") {
                    removeSelectedAction?()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(removeSelectedAction == nil)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Brim") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
                Button("Uninstall Brim...") {
                    showSelfUninstall = true
                }
            }
        }
    }
    
    private func performSelfUninstall() async {
        let bundleID = Bundle.main.bundleIdentifier ?? "devplaceholder.PJ52YXEB.brim"
        let identity = Identity(bundleID: bundleID, teamID: "PJ52YXEB", name: "Brim")
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        
        do {
            let plan = try await client.plan(intent: intent)
            let token = try await client.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
            try await client.apply(planId: plan.planId, token: token)
            // Quit immediately after applying the uninstall
            NSApplication.shared.terminate(nil)
        } catch {
            print("Failed to self-uninstall: \(error)")
        }
    }
}
