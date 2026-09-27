import SwiftUI

/// Where the window can be. Seven places in two groups of three, plus the
/// Journal on its own: few enough that the sidebar is read at a glance.
///
/// Updates and Energy are not places any more. They are lenses on Apps
/// (`AppsLens`), because both are questions about applications.
enum Destination: String, Hashable, CaseIterable {
    case home = "Home"
    case apps = "Apps"
    case leftovers = "Leftovers"
    case background = "Background"
    case space = "Space"
    case developer = "Developer"
    case journal = "Journal"

    static let brim: [Destination] = [.home, .apps, .leftovers]
    static let yourMac: [Destination] = [.background, .space, .developer]

    /// The order the person sees, and the only order anything may use.
    ///
    /// The sidebar once listed these in one order and the menu numbered
    /// them from `allCases`, which was a different one, so the shortcuts
    /// opened the wrong rows. Both read from this. It is also the vertical
    /// space page changes move through (`AnyTransition.brimPage`).
    static let displayOrder: [Destination] = brim + yourMac + [.journal]

    /// The number a person types with Command to get here.
    var keyboardDigit: Character? {
        guard let index = Self.displayOrder.firstIndex(of: self), index < 9 else { return nil }
        return Character("\(index + 1)")
    }

    var position: Int {
        Self.displayOrder.firstIndex(of: self) ?? 0
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .apps: "square.grid.2x2"
        case .leftovers: "shippingbox"
        case .background: "gearshape.2"
        case .space: "internaldrive"
        case .developer: "hammer"
        case .journal: "book.closed"
        }
    }
}

/// The views of Apps that used to be sections of their own.
enum AppsLens: String, Hashable, CaseIterable {
    case all = "All Apps"
    case updates = "Updates"
    case energy = "Energy"
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

struct MainSidebar: View {
    @Binding var selection: Destination?

    var body: some View {
        // `.tag` rather than `NavigationLink(value:)`. The link form belongs
        // to a NavigationStack path; inside a List driven by a selection
        // binding it produces rows that expose as AXUnknown and ignore an
        // accessibility press, so the sidebar looked operable to VoiceOver
        // and to automation while doing nothing.
        List(selection: $selection) {
            Section("Brim") {
                rows(Destination.brim)
            }
            Section("Your Mac") {
                rows(Destination.yourMac)
            }
            Section {
                rows([.journal])
            }
        }
        .listStyle(.sidebar)
    }

    private func rows(_ destinations: [Destination]) -> some View {
        ForEach(destinations, id: \.self) { destination in
            Label(destination.rawValue, systemImage: destination.icon)
                .tag(destination)
        }
    }
}
