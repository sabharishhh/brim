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
    /// Kept outside scene storage: granting Full Disk Access relaunches Brim,
    /// and a window that is not restored loses its scene storage.
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
    /// Setup runs once, whatever the person accepted. Asking every launch
    /// teaches people to dismiss it.
    @AppStorage("hasFinishedSetup") private var hasFinishedSetup = false
    /// Nil until asked. People who enrolled before this flag existed have
    /// already been through setup.
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
            // Keyed to the page, so only a page change animates, not every scroll and
            // checkbox inside it.
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
        // The window's own background. The sidebar draws its own over it,
        // the desktop seen through AppKit's material (`SidebarBackdrop`).
        .containerBackground(Palette.canvas, for: .window)
        .pointerStyle(.default)
        .buttonStyle(PointerButtonStyle(.automatic))
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
        // A minimum and deliberately no ideal size: an ideal on the root makes
        // SwiftUI measure the whole view tree on every pass, so every scroll ran a
        // window-wide constraint solve. `.defaultSize` sets the opening size.
        // Column minimums must add up to less than this, or a column grows the
        // window and the larger size is saved.
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
        .keepsCurrent(models, shell: shell)
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
        // Asked from the Dock, a Shortcut or Spotlight, maybe before this window.
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
        // Keeps the trailing control on the trailing edge on every page,
        // including those with nothing in the middle of the toolbar.
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) {
            CheckAgainButton(
                activity: models.activity, destination: shell.selection, lens: shell.appsLens,
                presses: shell.checkRequests, check: { shell.requestCheck() }, stop: models.developer.cancelScan
            )
        }
    }

    // MARK: - Full Disk Access

    /// After a Full Disk Access relaunch, return to the page (and Settings) the
    /// request came from. Once per launch.
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

    /// Access granted while Brim runs, which macOS often allows without a
    /// relaunch: read everything again.
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

/// Removed apps with something new left behind, on the Dock icon when
/// enabled in Settings. Observes the model directly, because nested
/// observable objects do not pass changes up.
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
