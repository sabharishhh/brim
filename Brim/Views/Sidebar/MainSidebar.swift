import BrimUI
import SwiftUI

/// Where the window can be: two short groups, plus the Journal on its own,
/// few enough that the sidebar is read at a glance.
///
/// Updates is a lens on Apps (`AppsLens`), because it is a question about
/// applications. Energy is a place under Your Mac, because it is about
/// what the Mac is doing now.
enum Destination: String, Hashable, CaseIterable {
    /// Brim's overview of this Mac, named for Brim like the app's own
    /// first page. A saved "Home" from an earlier build falls back here.
    case home = "Brim"
    case apps = "Apps"
    case leftovers = "Remnants"
    case background = "Background"
    case space = "Space"
    case developer = "Developer"
    case energy = "Energy"
    case journal = "Journal"

    static let brim: [Destination] = [.home, .apps, .leftovers]
    static let yourMac: [Destination] = [.background, .energy, .space, .developer]

    /// The order the person sees, and the only order anything may use.
    ///
    /// The sidebar once listed these in one order and the menu numbered
    /// them from `allCases`, which was a different one, so the shortcuts
    /// opened the wrong rows. Both read from this.
    static let displayOrder: [Destination] = brim + yourMac + [.journal]

    /// The number a person types with Command to get here.
    var keyboardDigit: Character? {
        guard let index = Self.displayOrder.firstIndex(of: self), index < 9 else { return nil }
        return Character("\(index + 1)")
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .apps: "square.grid.2x2"
        case .leftovers: "app.dashed"
        case .background: "gearshape.2"
        case .space: "internaldrive"
        case .developer: "hammer"
        case .energy: "bolt"
        case .journal: "book.closed"
        }
    }
}

/// The views of Apps that used to be sections of their own.
enum AppsLens: String, Hashable, CaseIterable {
    case all = "Apps"
    case updates = "Updates"
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
    /// Which places are still scanning, shown as a spinner on their row.
    @ObservedObject var activity: ScanActivity
    @EnvironmentObject private var release: BrimReleaseCheck

    var body: some View {
        // `.tag` rather than `NavigationLink(value:)`. The link form belongs
        // to a NavigationStack path; inside a List driven by a selection
        // binding it produces rows that expose as AXUnknown and ignore an
        // accessibility press, so the sidebar looked operable to VoiceOver
        // and to automation while doing nothing.
        List(selection: $selection) {
            // Home carries Brim's own icon, so a header naming Brim above it
            // said the same thing twice.
            Section {
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
        // A little air between the window controls and the first row.
        .contentMargins(.top, 8, for: .scrollContent)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let found = release.available {
                    NewReleaseNotice(release: found)
                        .padding(10)
                        .transition(.opacity)
                }
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                .padding(10)
            }
        }
    }

    private func rows(_ destinations: [Destination]) -> some View {
        ForEach(destinations, id: \.self) { destination in
            HStack {
                SidebarLabel(destination: destination, isSelected: selection == destination)
                Spacer()
                if activity.busy.contains(destination) {
                    ProgressView()
                        .controlSize(.mini)
                        .transition(.opacity)
                        .accessibilityLabel("Checking")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: activity.busy.contains(destination))
            .tag(destination)
        }
    }
}

/// A sidebar row's label. Its icon answers once when the row becomes
/// selected, so a click is answered by the thing clicked rather than only by
/// the highlight moving. Each place moves in its own way, small and short:
/// the gears turn, the hammer swings, the remnants breathe. Never on the row
/// being left, and never under Reduce Motion.
private struct SidebarLabel: View {
    let destination: Destination
    let isSelected: Bool
    @State private var arrivals = 0
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label {
            Text(destination.rawValue)
        } icon: {
            icon
        }
        .onChange(of: isSelected) { _, selected in
            if selected, !reduceMotion {
                arrivals += 1
            }
        }
    }

    @ViewBuilder private var icon: some View {
        let symbol = Image(systemName: destination.icon)
        switch destination {
        case .home:
            // An app icon carries its own margin inside the square, so it
            // is drawn larger than a symbol to look the same size.
            BrimIcon(source: .bundle(Bundle.main.bundleURL), size: 22)
                .keyframeAnimator(initialValue: 1.0, trigger: arrivals) { content, scale in
                    content.scaleEffect(scale)
                } keyframes: { _ in
                    SpringKeyframe(1.12, duration: 0.14, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.32, spring: .bouncy(extraBounce: 0.05))
                }
        case .apps:
            symbol.symbolEffect(.bounce.down, options: .nonRepeating, value: arrivals)
        case .leftovers:
            symbol.symbolEffect(.breathe, options: .nonRepeating, value: arrivals)
        case .background:
            symbol.symbolEffect(.rotate.byLayer, options: .nonRepeating, value: arrivals)
        case .energy:
            symbol.symbolEffect(.bounce.up, options: .nonRepeating, value: arrivals)
        case .space:
            symbol.symbolEffect(.pulse, options: .nonRepeating, value: arrivals)
        case .developer:
            symbol.symbolEffect(.wiggle.counterClockwise, options: .nonRepeating, value: arrivals)
        case .journal:
            symbol.symbolEffect(.wiggle.forward, options: .nonRepeating, value: arrivals)
        }
    }
}

/// A newer Brim is on GitHub. Brim does not replace itself, so this says
/// so and opens the release page.
private struct NewReleaseNotice: View {
    let release: BrimReleaseCheck.Release

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
            Text("Brim \(release.version) is out")
                .font(.callout)
            Spacer(minLength: 4)
            Button("Download") { NSWorkspace.shared.open(release.page) }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}
