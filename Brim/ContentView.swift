import SwiftUI
import BrimProtocol
import BrimUI

struct ContentView: View {
    @State private var selection: NavigationItem? = .review
    /// Owned here so a section change does not throw away a scan. See
    /// `SectionModels`.
    @StateObject private var models = SectionModels()
    @Environment(\.brimService) private var service
    /// Setup runs once and then never again, whether or not the person
    /// accepted everything in it. Asking again next launch is how an app
    /// trains people to dismiss without reading.
    @AppStorage("hasFinishedSetup") private var hasFinishedSetup = false
    /// nil until asked. Somebody who enrolled before this flag existed has
    /// already been through setup and should not see it again.
    @State private var needsSetup: Bool?

    var body: some View {
        NavigationSplitView {
            MainSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            if let selection = selection {
                switch selection {
                case .review:
                    ReviewSummaryView(navigationSelection: $selection, models: models)
                case .applications:
                    ApplicationsView(model: models.applications, access: models.fullDiskAccess)
                case .leftovers:
                    LeftoversView(model: models.leftovers, recovery: models.recovery)
                case .background:
                    BackgroundView(model: models.background)
                case .storage:
                    StorageView(model: models.storage)
                case .energy:
                    EnergyView(model: models.energy)
                case .developer:
                    DeveloperView(model: models.developer)
                case .updates:
                    UpdatesView(model: models.updates)
                case .history:
                    RemovalHistoryView(model: models.history, recovery: models.recovery)
                default:
                    Text("\(selection.rawValue) View")
                        .foregroundColor(.secondary)
                        .font(.title)
                }
            } else {
                Text("Select an item")
                    .foregroundColor(.secondary)
            }
        }
        // A section change is a change of view, and it should read as one.
        // Scoped to the selection so nothing inside a panel inherits it:
        // an animation applied to the whole detail column animates every
        // scroll and every checkbox underneath it, which costs frames and
        // makes the app feel slower rather than smoother.
        .animation(.easeOut(duration: 0.16), value: selection)
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
        .focusedSceneValue(\.navigateAction) { item in selection = item }
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
}
