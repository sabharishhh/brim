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
                    LeftoversView(model: models.leftovers)
                case .background:
                    BackgroundView(model: models.background)
                case .storage:
                    StorageView(model: models.storage)
                case .duplicates:
                    DuplicatesView(model: models.duplicates)
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
        // An ideal as well as a minimum. Without a concrete ideal the
        // content reports that it will take any width, `.defaultSize` is
        // ignored, and the window opens at whatever the display allows.
        .frame(minWidth: 900, idealWidth: 1200, minHeight: 600, idealHeight: 800)
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
