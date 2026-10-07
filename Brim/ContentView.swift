import BrimCore
import BrimProtocol
import BrimUI
import os
import QuickLook
import SwiftUI

struct ContentView: View {
    /// Where the window is, where it has been, Quick Look and the toast.
    @State private var shell = ShellState()
    /// Saved with the window, so it reopens where it was left.
    @SceneStorage("destination") private var savedDestination = Destination.home.rawValue
    @SceneStorage("appsLens") private var savedLens = AppsLens.all.rawValue
    /// The same place, kept outside the window's saved state. Granting Full
    /// Disk Access makes macOS quit and reopen Brim, and a window that is
    /// not restored (with "Close windows when quitting" on, or when Brim
    /// reopens itself) loses its scene storage. See `resumeAfterAccess`.
    @AppStorage("place.destination") private var lastDestination = Destination.home.rawValue
    @AppStorage("place.appsLens") private var lastLens = AppsLens.all.rawValue
    @SwiftUI.Environment(\.openSettings) private var openSettings
    /// Owned here so a section change does not throw away a scan. See
    /// `SectionModels`.
    @StateObject private var models = SectionModels()
    /// What outlives a launch, shared with Settings (`BrimAppMain`).
    @SwiftUI.Environment(AppSession.self) private var session
    @AppStorage(SettingsKey.dockBadge) private var showsDockBadge = false
    private let requests = ExternalRequests.shared
    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Setup runs once and then never again, whether or not the person
    /// accepted everything in it. Asking again next launch is how an app
    /// trains people to dismiss without reading.
    @AppStorage("hasFinishedSetup") private var hasFinishedSetup = false
    /// nil until asked. Somebody who enrolled before this flag existed has
    /// already been through setup and should not see it again.
    @State private var needsSetup: Bool?

    var body: some View {
        NavigationSplitView {
            MainSidebar(selection: Binding(
                get: { shell.selection },
                set: { destination in
                    if let destination {
                        shell.go(to: destination)
                    }
                }
            ), activity: models.activity)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            ZStack {
                page(shell.selection)
                    .id(shell.selection)
                    .transition(.replacement)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
            .overlay(alignment: .top) { ActivityLine(activity: models.activity) }
            // Keyed to the page, so a change of page is animated and
            // nothing inside one inherits it: an animation over the whole
            // column would animate every scroll and every checkbox too.
            // A fade replaces the old blur, scale and drift, which made the
            // page swim for 280 ms after every click; from the keyboard
            // the new page is simply there.
            .animation(
                shell.navigatedByKeyboard ? nil : Motion.resolved(Motion.navigate, reduceMotion: reduceMotion),
                value: shell.selection
            )
            // Pages with a list column centre the Tray and toast on that
            // column themselves; the rest show the toast across the page.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if ![.leftovers, .apps, .background, .developer].contains(shell.selection) {
                    ShellOverlay(tray: nil)
                }
            }
            .toolbar { toolbar }
            // One colour from the top of the window to the bottom. The
            // toolbar painted its own lighter band over pages whose list
            // did not reach under it, and showed it on hover elsewhere.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // Content passing under the toolbar fades out softly; a hard
            // edge draws a solid band down to the first row of a list.
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        // The window's own background, so the system sidebar is the canvas
        // seen through glass: a shade apart, with no line between them.
        .containerBackground(Palette.canvas, for: .window)
        .onAppear { LaunchSignpost.shellAppeared() }
        // Each page draws its own name in the toolbar (`pageTitle`); the
        // system's title would repeat it beside a subtitle.
        .toolbar(removing: .title)
        .overlay(alignment: .top) { commandBar }
        .quickLookPreview($shell.previewURL, in: shell.previewURLs)
        // The preview panel is not the key window, so Escape arrives here.
        .onKeyPress(.escape) {
            guard shell.isPreviewing else { return .ignored }
            shell.closePreview()
            return .handled
        }
        // An application dropped anywhere on the window opens it in Apps;
        // an installer, or an app that is not installed, opens a look
        // inside it.
        .dropDestination(for: URL.self) { urls, _ -> Bool in
            models.openApplication(from: urls, shell: shell)
        }
        .modifier(InstallerSheets(model: models.recording, shell: shell, applications: models.applications))
        // A minimum, and deliberately no ideal.
        //
        // This carried `idealWidth: 1200, idealHeight: 800` for the reason
        // written here before: without a concrete ideal the content said it
        // would take any width and the window opened at whatever the
        // display allowed. `.defaultSize` on the scene answers that now and
        // the ideal had become a second, redundant hint.
        //
        // It was also the single biggest cost in the app. An ideal size on
        // the root makes SwiftUI measure the *entire* content tree to
        // produce it, and hand the answer to AppKit as an intrinsic size,
        // so every scroll in any panel walked the whole view graph and then
        // ran a window-wide constraint solve. Profiling the Applications
        // list put 43% of the main thread in `GraphHost.flushTransactions`,
        // 25% in `-[NSWindow layoutIfNeeded]` and 14% in
        // `ViewGraphRootValueUpdater._sizeThatFits`, with not one sample
        // containing any of Brim's own code: no view body was running,
        // SwiftUI was re-measuring everything. Every panel had it, which is
        // why removing an HSplitView here and a ScrollView there each
        // helped a little and none of it fixed the feel.
        //
        // A minimum is a constant and costs nothing to answer.
        // The narrowest the layout holds together: the sidebar (200), a
        // list column (440) and a review pane (440), with room to spare.
        // Every column's minimum must add up to less than this, or a column
        // asking for more than the window has grows the window and the new
        // size is saved (`CLAUDE.md`, on minimum widths ratcheting).
        .frame(minWidth: Metrics.windowMinWidth, minHeight: Metrics.windowMinHeight)
        .focusedSceneValue(\.shell, shell)
        .environment(shell)
        .onAppear {
            shell.restore(Destination(rawValue: savedDestination) ?? .home)
            shell.appsLens = AppsLens(rawValue: savedLens) ?? .all
            resumeAfterAccess()
            models.fullDiskAccess.startObserving()
        }
        .onChange(of: shell.selection) { _, destination in
            savedDestination = destination.rawValue
            lastDestination = destination.rawValue
        }
        .onChange(of: shell.appsLens) { _, lens in
            savedLens = lens.rawValue
            lastLens = lens.rawValue
        }
        .onChange(of: models.fullDiskAccess.isGranted) { wasGranted, isGranted in
            if !wasGranted, isGranted {
                Task { await readAgainWithAccess() }
            }
        }
        .onChange(of: shell.checkRequests) { Task { await checkAgain() } }
        // Asks macOS nothing until a removal needs administrator access;
        // see `HelperRoute`.
        .task(id: needsSetup) {
            await HelperRoute.connect(models.background.helper, to: service)
            guard needsSetup == false else { return }
            await service.recheckPendingRemovals()
        }
        // Every installed app's icon, saved while the app is here to ask,
        // so its leftovers keep its face after it is removed.
        .onReceive(models.applications.$applications) { session.icons.remember($0) }
        // Asked from the Dock, a Shortcut or Spotlight, possibly before
        // this window existed.
        .task(id: requests.pending.count) { answerExternalRequests() }
        .background { DockBadge(leftovers: models.leftovers, isOn: showsDockBadge) }
        .task {
            guard needsSetup == nil else { return }
            if hasFinishedSetup {
                needsSetup = false
            } else {
                let enrolled = await service.isEnrolled()
                needsSetup = !enrolled
            }
        }
        .sheet(isPresented: Binding(
            get: { needsSetup == true },
            set: {
                if !$0 {
                    needsSetup = false
                }
            }
        )) {
            OnboardingSheet(service: service) {
                hasFinishedSetup = true
                needsSetup = false
            }
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private func page(_ destination: Destination) -> some View {
        switch destination {
        case .home:
            HomeView(models: models)
        case .apps:
            switch shell.appsLens {
            case .all: ApplicationsView(model: models.applications, access: models.fullDiskAccess)
            case .updates: UpdatesView(model: models.updates, whatsNew: models.whatsNew)
            }
        case .leftovers:
            LeftoversView(model: models.leftovers, recovery: models.recovery, access: models.fullDiskAccess)
        case .background:
            BackgroundView(model: models.background)
        case .energy:
            EnergyView(model: models.energy)
        case .space:
            SpaceView(
                model: models.storage, applications: models.applications,
                developer: models.developer, history: models.history, appData: models.appData
            )
        case .developer:
            DeveloperView(model: models.developer)
        case .journal:
            JournalView(model: models.history, recovery: models.recovery, applications: models.applications)
        }
    }

    // MARK: - Beyond the window

    @ViewBuilder
    private var commandBar: some View {
        if shell.showsCommandBar {
            ZStack(alignment: .top) {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture { shell.showsCommandBar = false }
                    .accessibilityHidden(true)
                CommandBar(shell: shell, applications: models.applications, leftovers: models.leftovers)
                    .padding(.top, 80)
            }
            .transition(.opacity)
        }
    }

    private func answerExternalRequests() {
        for request in requests.drain() {
            switch request {
            case let .open(urls):
                _ = models.openApplication(from: urls, shell: shell)
            case let .remove(url):
                shell.go(to: .apps, lens: .all)
                shell.pendingRemoval = url
            case let .show(destination):
                shell.go(to: destination)
            case .check:
                shell.requestCheck()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if shell.selection == .apps {
            ToolbarItem(placement: .principal) {
                LensSwitch(lens: $shell.appsLens, updates: models.updates)
            }
        }
        // Keeps Check Again on the trailing edge on every page, including
        // those with nothing in the middle of the toolbar.
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) {
            CheckAgainButton(
                activity: models.activity, destination: shell.selection, presses: shell.checkRequests,
                check: { shell.requestCheck() }, stop: models.developer.cancelScan
            )
        }
    }

    // MARK: - Full Disk Access

    /// The launch after a request for Full Disk Access goes back to where
    /// the request was made: the same page, and the Settings window if it
    /// was asked from there. Setup keeps its own step. Once, per launch.
    private func resumeAfterAccess() {
        guard !Self.resumed, let origin = FullDiskAccess.pendingRequest else { return }
        Self.resumed = true
        shell.restore(Destination(rawValue: lastDestination) ?? .home)
        shell.appsLens = AppsLens(rawValue: lastLens) ?? .all
        if origin == .settings {
            openSettings()
        }
        // A fresh launch either has access or the switch was not turned on.
        // Either way the request is answered, and the pages go back to
        // offering System Settings rather than another reopen.
        FullDiskAccess.clearRequest()
        models.fullDiskAccess.recheck()
    }

    @MainActor private static var resumed = false

    /// Access arrived while Brim was running, which macOS often allows
    /// without the reopen it offers. Everything read without it is read
    /// again, so no page keeps saying Library could not be read.
    private func readAgainWithAccess() async {
        shell.show(ToastMessage(symbol: "checkmark.circle", text: "Full Disk Access is on"))
        async let leftovers: Void = models.leftovers.load(service: service)
        async let background: Void = models.background.load(service: service)
        async let storage: Void = models.storage.load(service: service)
        async let recovery: Void = models.recovery.refresh(service: service)
        _ = await (leftovers, background, storage, recovery)
        // The inspector's "behind Full Disk Access, not counted" too.
        if let selected = models.applications.selected {
            models.applications.select(selected)
        }
    }

    /// Reads the current page again from the Mac.
    private func checkAgain() async {
        switch shell.selection {
        case .home:
            async let leftovers: Void = models.leftovers.load(service: service)
            async let applications: Void = models.applications.load(service: service)
            async let recovery: Void = models.recovery.refresh(service: service)
            _ = await (leftovers, applications, recovery)
        case .apps:
            switch shell.appsLens {
            case .all: await models.applications.load(service: service)
            case .updates: await models.updates.load(service: service)
            }
        case .leftovers: await models.leftovers.load(service: service)
        case .background: await models.background.load(service: service)
        case .space:
            await models.storage.load(service: service)
            await models.appData.measure(
                service: service, applications: models.applications.applications, developer: models.developer.caches
            )
        case .developer: await models.developer.load(service: service)
        case .energy: await models.energy.sample(service: service)
        case .journal:
            // Installs are read from the snapshots, and listing the apps is
            // what writes one, so an app installed since the last look
            // appears only if the list is read first.
            await models.applications.load(service: service)
            await models.history.load(service: service)
        }
    }
}

/// The brim line under the toolbar, running while any place is scanning,
/// and gone when nothing is, so an idle window draws nothing.
private struct ActivityLine: View {
    @ObservedObject var activity: ScanActivity

    var body: some View {
        ZStack {
            if !activity.busy.isEmpty {
                BrimLine(work: .indeterminate)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: activity.busy.isEmpty)
        .accessibilityHidden(activity.busy.isEmpty)
    }
}

/// Removed apps with something new left behind since the last visit, on
/// the Dock icon, when the person asked for it in Settings. Opening
/// Remnants acknowledges them, which clears it. It counted every path,
/// Unknown items included, under a setting that says removed apps. Its own
/// view, observing the model directly: read through `SectionModels` it
/// would never hear of a change (`CLAUDE.md`, on nested observable objects).
private struct DockBadge: View {
    @ObservedObject var leftovers: LeftoversModel
    let isOn: Bool
    @SwiftUI.Environment(AppSession.self) private var session

    var body: some View {
        Color.clear
            .task(id: count) { NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil }
            .accessibilityHidden(true)
    }

    private var count: Int {
        guard isOn else { return 0 }
        return session.visits.newItems(in: "removed apps", current: Set(leftovers.orphanedGroups.map(\.id))).count
    }
}

/// Launch to the first usable window, as one Points of Interest interval:
/// begun when the app is made and ended when its window first appears.
@MainActor
enum LaunchSignpost {
    private static var interval: OSSignpostIntervalState?

    static func begin() {
        interval = BrimLog.signposter.beginInterval("Launch to shell")
    }

    static func shellAppeared() {
        guard let interval else { return }
        BrimLog.signposter.endInterval("Launch to shell", interval)
        Self.interval = nil
    }
}
