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

    /// The order the person sees, and the only order anything may use.
    ///
    /// The sidebar listed these in one order and the View menu numbered
    /// them from `allCases`, which is a different one, so the shortcuts
    /// opened the wrong rows and the last section had none at all. Both
    /// read from this now, so there is one order rather than two that have
    /// to be kept in step.
    static let primary: [NavigationItem] = [
        .review, .applications, .leftovers, .background, .storage, .energy,
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
        case .energy: return "bolt.fill"
        case .developer: return "hammer"
        case .updates: return "arrow.triangle.2.circlepath"
        case .history: return "clock"
        }
    }
}

/// A command a view offers to the menu bar, equal to any other with the
/// same name.
///
/// A focused value that is a bare closure can never compare equal to the
/// one before it, so SwiftUI treated every redraw as a change of focus
/// state. The scene reads these values to build its menus, so the menus
/// were rebuilt, the window's root was rebuilt with them, and that redraw
/// published yet another closure. With Brim frontmost the main thread sat
/// at 100% doing nothing else, which is what made every list in the app
/// scroll badly: a sample of an idle window scrolled once showed the loop
/// still running twenty seconds later, and hiding Brim dropped it to 0%.
/// The closures captured state storage rather than values, so the one
/// already delivered stays correct and a new one is not needed.
struct FocusedAction<Input>: Equatable {
    let name: String
    let perform: (Input) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name
    }
}

/// Lets a section offer "Remove Selected" to the Action menu.
///
/// Defined here rather than in the view that provides it, because the
/// provider changes: this began in the Review queue and moved to Leftovers
/// when that queue was removed, and the command should not break each time.
struct RemoveSelectedActionKey: FocusedValueKey {
    typealias Value = FocusedAction<Void>
}

extension FocusedValues {
    var removeSelectedAction: FocusedAction<Void>? {
        get { self[RemoveSelectedActionKey.self] }
        set { self[RemoveSelectedActionKey.self] = newValue }
    }
}

/// Lets the View menu drive sidebar selection, so every section is
/// reachable from the keyboard as a Mac app is expected to be.
struct NavigateActionKey: FocusedValueKey {
    typealias Value = FocusedAction<NavigationItem>
}

extension FocusedValues {
    var navigateAction: FocusedAction<NavigationItem>? {
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
