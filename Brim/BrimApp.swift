import BrimCore
import BrimPrivileged
import BrimProtocol
import BrimUI
import Foundation
import os
import SwiftUI

private let log = BrimLog.make("app")

@main struct BrimAppMain: App {
    @FocusedValue(\.removeSelectedAction) var removeSelectedAction
    @FocusedValue(\.shell) var shell
    @FocusedValue(\.selectedItems) var selectedItems

    let client: any BrimServiceProtocol = BrimServiceLocator.makeService()
    /// The Dock's menu, and apps dropped on its icon.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// What outlives a launch: kept items, what was seen, saved icons.
    /// One for the app, so Settings and the window agree.
    @State private var session = AppSession()
    @State private var feedback = FeedbackConfiguration.makeModel()
    /// View ▸ Compact Rows, for everyone who prefers density.
    @AppStorage("rows.compact") private var compactRows = false

    init() {
        LaunchSignpost.begin()
        BrimTips.configure()
    }

    @State private var showSelfUninstall = false
    /// Whether a newer Brim is on GitHub.
    @StateObject private var release = BrimReleaseCheck()
    /// What Check for Brim Updates found, while its reply is showing.
    @State private var releaseAnswer: BrimReleaseCheck.Answer?

    /// What went wrong removing Brim, when something did.
    ///
    /// This has to reach the person rather than a log. They pressed a
    /// button called "Uninstall Brim", and the two ways it fails are both
    /// ones where the window staying open is the only clue they get.
    @State private var selfUninstallProblem: String?

    var body: some Scene {
        mainWindow
        Settings {
            SettingsView()
                .environment(session)
                .environment(feedback)
        }
        .windowResizability(.contentSize)
        Window("Feedback", id: FeedbackWindow.windowID) {
            FeedbackWindow()
                .environment(feedback)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        Window("Keyboard Shortcuts", id: ShortcutsView.windowID) {
            ShortcutsView()
        }
        .windowResizability(.contentSize)
        Window("About Brim", id: AboutView.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
    }

    private var mainWindow: some Scene {
        WindowGroup {
            root
                .environment(\.brimService, client)
                .environment(session)
                .environment(feedback)
                .environment(\.compactRows, compactRows)
                .environmentObject(release)
                .task { await release.checkIfDue() }
                .alert(releaseTitle, isPresented: Binding(
                    get: { releaseAnswer != nil },
                    set: {
                        if !$0 {
                            releaseAnswer = nil
                        }
                    }
                )) {
                    if case let .newer(found) = releaseAnswer {
                        Button("Download") { NSWorkspace.shared.open(found.page) }
                        Button("Later", role: .cancel) {}
                    } else {
                        Button("OK", role: .cancel) {}
                    }
                } message: {
                    Text(releaseMessage)
                }
                .alert(SelfRemoval.confirmationTitle, isPresented: $showSelfUninstall) {
                    Button("Cancel", role: .cancel) {}
                    Button("Remove Brim", role: .destructive) {
                        Task { await performSelfUninstall() }
                    }
                } message: {
                    Text(SelfRemoval.confirmationMessage)
                }
                .alert(
                    "Brim has not removed itself",
                    isPresented: Binding(
                        get: { selfUninstallProblem != nil },
                        set: {
                            if !$0 {
                                selfUninstallProblem = nil
                            }
                        }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(selfUninstallProblem ?? "")
                }
        }
        // 900 is the floor (`Metrics.windowMinWidth`), and `.contentMinSize`
        // stops the window being dragged below it from any edge or corner.
        // It was 1100, the sidebar plus a list plus a review pane side by
        // side; below that width the pane now floats over the list
        // (`AdaptivePanes`), and Home's cards wrap two by two.
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
            CommandGroup(after: .help) {
                ShortcutsMenuItem()
                FeedbackMenuItem()
                    .environment(feedback)
            }
            CommandMenu("Go") {
                Button("Go To or Find") { shell?.showsCommandBar.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(shell == nil)
                Divider()
                Button("Back") { shell?.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!(shell?.canGoBack ?? false))
                Button("Forward") { shell?.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!(shell?.canGoForward ?? false))
                Divider()
                // Numbered from the order the sidebar renders, not from
                // the enum's declaration order. Those were different once,
                // so Command-6 opened the seventh row.
                ForEach(Destination.displayOrder, id: \.self) { destination in
                    Button(destination.rawValue) { shell?.go(to: destination) }
                        .keyboardShortcut(KeyEquivalent(destination.keyboardDigit ?? "0"), modifiers: .command)
                        .disabled(shell == nil)
                }
            }
            CommandGroup(before: .sidebar) {
                Toggle("Compact Rows", isOn: $compactRows)
                    .keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                Button("Check Again") { shell?.requestCheck() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(shell == nil)
                Divider()
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Reveal in Finder") { shell?.reveal(selectedItems?.urls ?? []) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(selectedItems?.urls.isEmpty ?? true)
                Button("Quick Look") { shell?.quickLook(selectedItems?.urls ?? []) }
                    .keyboardShortcut("y", modifiers: .command)
                    .disabled(selectedItems?.urls.isEmpty ?? true)
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy Path") { shell?.copyPaths(selectedItems?.urls ?? []) }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(selectedItems?.urls.isEmpty ?? true)
            }
            CommandMenu("Action") {
                Button("Remove Selected") {
                    removeSelectedAction?.perform(())
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(removeSelectedAction == nil)
            }
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
                Button("Check for Brim Updates…") {
                    Task { releaseAnswer = await release.check() }
                }
                .disabled(release.isChecking)
                Divider()
                Button("Remove Brim…") {
                    showSelfUninstall = true
                }
            }
        }
    }

    private var releaseTitle: String {
        switch releaseAnswer {
        case let .newer(found): "Brim \(found.version) is available"
        case let .current(version): "Brim \(version) is the latest"
        default: "Couldn't reach GitHub"
        }
    }

    private var releaseMessage: String {
        switch releaseAnswer {
        case .newer: "Download it from GitHub and replace this copy in Applications."
        case .current: "You have the newest version."
        default: "Check your connection and try again."
        }
    }

    /// The app, or in a debug build launched with `-designGallery YES`,
    /// every design system component on one page.
    @ViewBuilder private var root: some View {
        if DesignGallery.isRequested {
            DesignGallery()
        } else {
            ContentView()
        }
    }

    /// The root daemon, so its own cleanup can run before Brim goes.
    @StateObject private var helper = PrivilegedHelperClient()

    private func performSelfUninstall() async {
        selfUninstallProblem = await SelfRemoval.perform(helper: helper)
    }
}
