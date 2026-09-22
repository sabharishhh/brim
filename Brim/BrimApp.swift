import Foundation
import os
import SwiftUI
import BrimProtocol
import BrimCore
import BrimUI
import BrimPrivileged

private let log = BrimLog.make("app")

@main struct BrimAppMain: App {
    @FocusedValue(\.removeSelectedAction) var removeSelectedAction
    @FocusedValue(\.navigateAction) var navigateAction
    
    let client: any BrimServiceProtocol = BrimServiceLocator.makeService()
    
    @State private var showSelfUninstall = false

    /// What went wrong removing Brim, when something did.
    ///
    /// This has to reach the person rather than a log. They pressed a
    /// button called "Uninstall Brim", and the two ways it fails are both
    /// ones where the window staying open is the only clue they get.
    @State private var selfUninstallProblem: String?

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
                .alert(
                    "Brim has not removed itself",
                    isPresented: Binding(
                        get: { selfUninstallProblem != nil },
                        set: { if !$0 { selfUninstallProblem = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(selfUninstallProblem ?? "")
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
                // Numbered from the order the sidebar renders, not from
                // the enum's declaration order. Those were different, so
                // Command-6 opened the seventh row.
                ForEach(NavigationItem.displayOrder, id: \.self) { item in
                    // Only the ones with a digit get a shortcut. Giving
                    // the tenth a fallback key would attach something
                    // nobody expects to a menu item, which is worse than
                    // it having none.
                    if let digit = item.keyboardDigit {
                        Button(item.rawValue) { navigateAction?(item) }
                            .keyboardShortcut(KeyEquivalent(digit), modifiers: .command)
                            .disabled(navigateAction == nil)
                    } else {
                        Button(item.rawValue) { navigateAction?(item) }
                            .disabled(navigateAction == nil)
                    }
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
                Button("Uninstall Brim…") {
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
            log.error("the helper did not clean up after itself: \(complaint)")
            // `uninstall` unregisters the daemon whether or not its own
            // cleanup worked, and only the running daemon can clear a folder
            // owned by root, so at this point the folder is there for good.
            // Removing Brim now would take away the only thing that knows,
            // which is the failure this product exists to point at in other
            // people's software.
            selfUninstallProblem =
                "The helper that runs as an administrator could not clear its own folder "
                + "before it was unregistered, so \(BrimJobHelper.quarantineDirectory) is "
                + "still on the disk and belongs to root. Removing it now needs an "
                + "administrator, which Finder will ask for.\n\n"
                + "Brim is untouched, so nothing else has been removed. Asking again will "
                + "remove Brim, but it will not remove that folder.\n\n"
                + complaint
            return
        }

        do {
            let plan = try await client.plan(intent: intent)
            try await client.approveAndApply(
                planId: plan.planId, requesterIdentity: NSUserName()
            )
            // Quit immediately after applying the uninstall
            NSApplication.shared.terminate(nil)
        } catch {
            log.error("could not remove Brim: \(error.localizedDescription)")
            selfUninstallProblem = "Brim could not remove itself. \(error.localizedDescription)"
        }
    }
}
