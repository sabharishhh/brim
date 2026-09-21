import SwiftUI
import BrimProtocol
import BrimUI

struct ContentView: View {
    @State private var selection: NavigationItem? = .review
    /// Owned here so a section change does not throw away a scan. See
    /// `SectionModels`.
    @StateObject private var models = SectionModels()
    @Environment(\.brimService) private var service
    /// nil until asked; the sheet only appears on a genuinely first run.
    @State private var needsWelcome: Bool?

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
                    ApplicationsView(model: models.applications)
                case .leftovers:
                    LeftoversView(model: models.leftovers)
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
        .focusedSceneValue(\.navigateAction) { item in selection = item }
        .task {
            if needsWelcome == nil { needsWelcome = !(await service.isEnrolled()) }
        }
        .sheet(isPresented: Binding(
            get: { needsWelcome == true },
            set: { if !$0 { needsWelcome = false } }
        )) {
            WelcomeSheet(service: service) { needsWelcome = false }
        }
    }
}
