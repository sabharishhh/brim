import SwiftUI

enum NavigationItem: String, Hashable, CaseIterable {
    case review = "Review"
    case applications = "Applications"
    case leftovers = "Leftovers"
    case background = "Background"
    case storage = "Storage"
    case energy = "Energy"
    case duplicates = "Duplicates"
    
    // Developer & System
    case developer = "Developer"
    case updates = "Updates"
    case history = "History"

    /// The order the person sees, and the only order anything may use.
    ///
    /// The sidebar listed these in one order and the View menu numbered
    /// them from `allCases`, which is a different one. Command-6 opened
    /// Energy while Energy was the seventh row, Command-7 opened
    /// Duplicates while Duplicates was the sixth, and History had no
    /// shortcut at all because the menu took the first nine of a list
    /// that ended somewhere else. Both read from this now, so there is
    /// one order rather than two that have to be kept in step.
    static let primary: [NavigationItem] = [
        .review, .applications, .leftovers, .background, .storage, .duplicates, .energy,
    ]
    static let system: [NavigationItem] = [.developer, .updates, .history]
    static let displayOrder: [NavigationItem] = primary + system

    /// The number a person types with Command to get here, when there is
    /// one. Ten sections and nine digits, so the last one has none rather
    /// than a shortcut nobody would guess.
    var keyboardDigit: Character? {
        guard let index = Self.displayOrder.firstIndex(of: self), index < 9 else { return nil }
        return Character("\(index + 1)")
    }

    var icon: String {
        switch self {
        case .review: return "checkmark.circle"
        case .applications: return "app.badge"
        case .leftovers: return "trash"
        case .background: return "gearshape.2"
        case .storage: return "internaldrive"
        case .duplicates: return "doc.on.doc"
        case .energy: return "bolt.fill"
        case .developer: return "hammer"
        case .updates: return "arrow.triangle.2.circlepath"
        case .history: return "clock"
        }
    }
}

/// Lets a section offer "Remove Selected" to the Action menu.
///
/// Defined here rather than in the view that provides it, because the
/// provider changes: this began in the Review queue and moved to Leftovers
/// when that queue was removed, and the command should not break each time.
struct RemoveSelectedActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var removeSelectedAction: (() -> Void)? {
        get { self[RemoveSelectedActionKey.self] }
        set { self[RemoveSelectedActionKey.self] = newValue }
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
                ForEach(NavigationItem.primary, id: \.self) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
                }
            }

            Section("System") {
                ForEach(NavigationItem.system, id: \.self) { item in
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
