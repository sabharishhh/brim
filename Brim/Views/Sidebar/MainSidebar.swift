import SwiftUI

enum NavigationItem: String, Hashable, CaseIterable {
    case review = "Review"
    case applications = "Applications"
    case leftovers = "Leftovers"
    case background = "Background"
    case storage = "Storage"
    case energy = "Energy"
    
    // Developer & System
    case developer = "Developer"
    case updates = "Updates"
    case history = "History"
    
    var icon: String {
        switch self {
        case .review: return "checkmark.circle"
        case .applications: return "app.badge"
        case .leftovers: return "trash"
        case .background: return "gearshape.2"
        case .storage: return "internaldrive"
        case .energy: return "bolt.fill"
        case .developer: return "hammer"
        case .updates: return "arrow.triangle.2.circlepath"
        case .history: return "clock"
        }
    }
}

/// Lets the View menu drive sidebar selection, so every section is
/// reachable from the keyboard as a Mac app is expected to be.
struct NavigateActionKey: FocusedValueKey {
    typealias Value = (NavigationItem) -> Void
}

extension FocusedValues {
    var navigateAction: ((NavigationItem) -> Void)? {
        get { self[NavigateActionKey.self] }
        set { self[NavigateActionKey.self] = newValue }
    }
}

struct MainSidebar: View {
    @Binding var selection: NavigationItem?

    var body: some View {
        // `.tag` rather than `NavigationLink(value:)`. The link form belongs
        // to a NavigationStack path; inside a List driven by a selection
        // binding it produces rows that expose as AXUnknown and ignore an
        // accessibility press — so the sidebar looked operable to VoiceOver
        // and to automation while doing nothing.
        List(selection: $selection) {
            Section("Primary") {
                ForEach([NavigationItem.review, .applications, .leftovers, .background, .storage, .energy], id: \.self) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
                }
            }

            Section("System") {
                ForEach([NavigationItem.developer, .updates, .history], id: \.self) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        // Monochromatic accent constraint
        .accentColor(.primary)
    }
}
