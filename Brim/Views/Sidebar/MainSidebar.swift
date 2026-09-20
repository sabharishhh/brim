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

struct MainSidebar: View {
    @Binding var selection: NavigationItem?

    var body: some View {
        List(selection: $selection) {
            Section("Primary") {
                ForEach([NavigationItem.review, .applications, .leftovers, .background, .storage, .energy], id: \.self) { item in
                    NavigationLink(value: item) {
                        Label(item.rawValue, systemImage: item.icon)
                    }
                }
            }
            
            Section("System") {
                ForEach([NavigationItem.developer, .updates, .history], id: \.self) { item in
                    NavigationLink(value: item) {
                        Label(item.rawValue, systemImage: item.icon)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Monochromatic accent constraint
        .accentColor(.primary)
    }
}
