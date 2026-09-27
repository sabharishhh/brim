import QuickLook
import SwiftUI
import BrimProtocol
import BrimUI

struct ContentView: View {
    /// Where the window is, where it has been, Quick Look and the toast.
    @State private var shell = ShellState()
    /// Saved with the window, so it reopens where it was left.
    @SceneStorage("destination") private var savedDestination = Destination.home.rawValue
    @SceneStorage("appsLens") private var savedLens = AppsLens.all.rawValue
    /// Owned here so a section change does not throw away a scan. See
    /// `SectionModels`.
    @StateObject private var models = SectionModels()
    /// What outlives a launch: kept items, what was seen, saved icons.
    @State private var session = AppSession()
    /// What the current page has picked to remove, shown as the Tray.
    @State private var tray: TrayContents?
    /// What a Home tile's title morphs through into its page.
    @Namespace private var pages
    @Environment(\.brimService) private var service
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            ))
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            ZStack {
                page(shell.selection)
                    .id(shell.selection)
                    .transition(.brimPage(movingDown: shell.movedDown, reduceMotion: reduceMotion))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.paper)
            // Keyed to the page, so a change of page is animated and
            // nothing inside one inherits it: an animation over the whole
            // column would animate every scroll and every checkbox too.
            .animation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion), value: shell.selection)
            .environment(\.pageNamespace, pages)
            .onPreferenceChange(TrayKey.self) { tray = $0 }
            .safeAreaInset(edge: .bottom, spacing: 0) { ShellOverlay(tray: tray) }
            .toolbar { toolbar }
        }
        .quickLookPreview($shell.previewURL, in: shell.previewURLs)
        // The preview panel is not the key window, so Escape arrives here.
        .onKeyPress(.escape) {
            guard shell.isPreviewing else { return .ignored }
            shell.closePreview()
            return .handled
        }
        // An application dropped anywhere on the window opens it in Apps.
        .dropDestination(for: URL.self) { urls, _ in
            models.openApplication(from: urls, shell: shell)
        }
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
        .frame(minWidth: 900, minHeight: 600)
        .focusedSceneValue(\.shell, shell)
        .environment(shell)
        .onAppear {
            shell.restore(Destination(rawValue: savedDestination) ?? .home)
            shell.appsLens = AppsLens(rawValue: savedLens) ?? .all
        }
        .onChange(of: shell.selection) { _, destination in savedDestination = destination.rawValue }
        .onChange(of: shell.appsLens) { _, lens in savedLens = lens.rawValue }
        .onChange(of: shell.checkRequests) { Task { await checkAgain() } }
        // Once, for every section. Asks macOS nothing until a removal
        // needs the helper; see `HelperRoute`.
        .task { await HelperRoute.connect(models.background.helper, to: service) }
        .task { session.visits.begin() }
        // Every installed app's icon, saved while the app is here to ask,
        // so its leftovers keep its face after it is removed.
        .onReceive(models.applications.$applications) { session.icons.remember($0) }
        .environment(session)
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
            set: { if !$0 { needsSetup = false } }
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
            case .updates: UpdatesView(model: models.updates)
            case .energy: EnergyView(model: models.energy)
            }
        case .leftovers:
            LeftoversView(model: models.leftovers, recovery: models.recovery)
        case .background:
            BackgroundView(model: models.background)
        case .space:
            StorageView(model: models.storage)
        case .developer:
            DeveloperView(model: models.developer)
        case .journal:
            RemovalHistoryView(model: models.history, recovery: models.recovery)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if shell.selection == .apps {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $shell.appsLens) {
                    ForEach(AppsLens.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                shell.requestCheck()
            } label: {
                Label("Check Again", systemImage: "arrow.clockwise")
            }
            .help("Check this page again (⌘R)")
        }
    }

    /// Reads the current page again from the Mac.
    private func checkAgain() async {
        switch shell.selection {
        case .home:
            async let leftovers: Void = models.leftovers.load(service: service)
            async let applications: Void = models.applications.load(service: service)
            _ = await (leftovers, applications)
        case .apps:
            switch shell.appsLens {
            case .all: await models.applications.load(service: service)
            case .updates: await models.updates.load(service: service)
            case .energy: await models.energy.sample(service: service)
            }
        case .leftovers: await models.leftovers.load(service: service)
        case .background: await models.background.load(service: service)
        case .space: await models.storage.load(service: service)
        case .developer: await models.developer.load(service: service)
        case .journal: await models.history.load(service: service)
        }
    }
}
