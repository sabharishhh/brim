import Foundation
import SwiftUI
import BrimProtocol
import BrimCore
import BrimUI
import BrimPrivileged

@main struct BrimAppMain: App {
    @FocusedValue(\.removeSelectedAction) var removeSelectedAction
    @FocusedValue(\.navigateAction) var navigateAction
    
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
                    Text("This removes Brim, the helper that runs as an administrator, its "
                         + "background agents and everything it has written. Any job files "
                         + "Brim set aside for you go with it, so restore anything you still "
                         + "want first.")
                }
        }
        // The widest section needs the sidebar (200) plus a two pane split
        // (620), so 900 is the floor, and `.contentMinSize` stops the window
        // being dragged below what the layout supports.
        //
        // The 1200x800 default is not currently honoured on this machine:
        // the window opens at roughly half the display width whatever is
        // set here. Ruled out so far: a saved window frame, saved split
        // view frames, saved application state, `windowResizability`, and
        // the content reporting an infinite width. Left in place because it
        // is correct, and noted because it is not yet taking effect.
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            // Every section reachable from the keyboard, the way a Mac app
            // is expected to behave. `after: .sidebar` puts these in the
            // standard View menu next to "Hide Sidebar" — a CommandMenu named
            // "View" would create a second menu of the same name instead.
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(Array(NavigationItem.allCases.prefix(9).enumerated()), id: \.element) { index, item in
                    Button(item.rawValue) { navigateAction?(item) }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(index + 1)")),
                            modifiers: .command
                        )
                        .disabled(navigateAction == nil)
                }
            }
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
    
    /// The root daemon, so its own cleanup can run before Brim goes.
    @StateObject private var helper = PrivilegedHelperClient()

    private func performSelfUninstall() async {
        let bundleID = Bundle.main.bundleIdentifier ?? "devplaceholder.PJ52YXEB.brim"
        let identity = Identity(bundleID: bundleID, teamID: "PJ52YXEB", name: "Brim")
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        
        // The daemon first, while it is still running. Its quarantine is
        // root owned, so nothing left behind can remove it afterwards, and
        // an uninstaller that leaves a root-owned folder on the disk is
        // the exact failure this product exists to point at.
        if let complaint = await helper.uninstall() {
            print("The helper did not clean up after itself: \(complaint)")
        }

        do {
            let plan = try await client.plan(intent: intent)
            try await client.approveAndApply(
                planId: plan.planId, requesterIdentity: NSUserName()
            )
            // Quit immediately after applying the uninstall
            NSApplication.shared.terminate(nil)
        } catch {
            print("Failed to self-uninstall: \(error)")
        }
    }
}
