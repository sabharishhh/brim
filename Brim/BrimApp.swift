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
    @FocusedValue(\.pageActions) var pageActions
    @FocusedValue(\.shell) var shell
    @FocusedValue(\.selectedItems) var selectedItems

    let client: any BrimServiceProtocol = BrimServiceLocator.makeService()
    /// Every request to the on-device model, one at a time, remembered in
    /// Brim's caches folder.
    let intelligence = IntelligenceEngine(
        reader: SystemLanguageReader(),
        cacheFile: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.sabharishhh.brim/Intelligence/answers.json")
    )
    /// The Dock's menu, and apps dropped on its icon.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// State that outlives a launch, shared by the window and Settings.
    @State private var session = AppSession()
    @State private var feedback = FeedbackConfiguration.makeModel()
    /// View ▸ Compact Rows, for everyone who prefers density.
    @AppStorage("rows.compact") private var compactRows = false

    init() {
        LaunchSignpost.begin()
        Self.useOwnAccent()
        BrimTips.configure()
    }

    /// AppKit draws some controls from the system accent, out of a SwiftUI tint's
    /// reach. An out-of-range `AppleAccentColor` in Brim's own domain reads as
    /// Multicolor, which uses the app's grey accent asset and keeps the window
    /// buttons coloured. Graphite (-1) turned them grey.
    private static func useOwnAccent() {
        let defaults = UserDefaults.standard
        defaults.set(-2, forKey: "AppleAccentColor")
        defaults.set("0.847059 0.847059 0.862745 Graphite", forKey: "AppleHighlightColor")
    }

    @State private var showSelfUninstall = false
    /// Whether a newer Brim is on GitHub.
    @StateObject private var release = BrimReleaseCheck()
    /// What Check for Brim Updates found, while its reply is showing.
    @State private var releaseAnswer: BrimReleaseCheck.Answer?

    /// Shown in the window: when removing Brim fails, it is the only clue.
    @State private var selfUninstallProblem: String?

    var body: some Scene {
        mainWindow
        Settings {
            SettingsView()
                .tint(Palette.tint)
                .environment(\.intelligence, intelligence)
                .environment(session)
                .environment(feedback)
        }
        .windowResizability(.contentSize)
        Window("Feedback", id: FeedbackWindow.windowID) {
            FeedbackWindow()
                .tint(Palette.tint)
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
                .tint(Palette.tint)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
    }

    private var mainWindow: some Scene {
        WindowGroup {
            root
                // Opening an installer with Brim while it ran made a second
                // window for it. The open window takes every external event.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                // Monochrome: the person's system accent would colour
                // checkboxes, switches and the sidebar selection.
                .tint(Palette.tint)
                .environment(\.brimService, client)
                .environment(\.intelligence, intelligence)
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
        // `.contentMinSize` stops the window being dragged below
        // `Metrics.windowMinWidth`. A hosted AppKit view can silently override
        // `.defaultSize`.
        .defaultSize(width: 1200, height: 800)
        .handlesExternalEvents(matching: ["*"])
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
                // Numbered in sidebar order, not the enum's declaration order.
                ForEach(Destination.displayOrder, id: \.self) { destination in
                    Button(destination.rawValue) { shell?.go(to: destination) }
                        .keyboardShortcut(KeyEquivalent(destination.keyboardDigit ?? "0"), modifiers: .command)
                        .disabled(shell == nil)
                }
                // The other half of the Apps and Updates switch.
                Button("Updates") { shell?.go(to: .apps, lens: .updates) }
                    .disabled(shell == nil)
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
                Button("Look Inside an Installer…") { shell?.chooseInstaller() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(shell == nil)
                Divider()
                Button("Show in Finder") { shell?.reveal(selectedItems?.urls ?? []) }
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
                if let pageActions, !pageActions.isEmpty {
                    Divider()
                    ForEach(pageActions, id: \.name) { action in
                        Button(action.name) { action.perform(()) }
                    }
                }
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

    /// The administrator process, so its own cleanup can run before Brim goes.
    @StateObject private var helper = PrivilegedHelperClient()

    private func performSelfUninstall() async {
        selfUninstallProblem = await SelfRemoval.perform(helper: helper)
    }
}
