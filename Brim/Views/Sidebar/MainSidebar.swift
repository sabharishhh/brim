import BrimUI
import SwiftUI

/// Where the window can be: two short groups, plus the Journal on its own,
/// few enough that the sidebar is read at a glance.
///
/// Updates is a lens on Apps (`AppsLens`), because it is a question about
/// applications. Energy is a place under Your Mac, because it is about
/// what the Mac is doing now.
enum Destination: String, Hashable, CaseIterable {
    /// The overview of this Mac, and where the window opens.
    case home = "Home"
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

/// The commands a page shows in its toolbar, offered to the Action menu as
/// well. Apple's guidance is that a toolbar item must also be a menu
/// command, because a toolbar can be hidden or customised; Update All,
/// emptying the Trash and clearing the Journal were in the toolbar only.
struct PageActionsKey: FocusedValueKey {
    typealias Value = [FocusedAction<Void>]
}

extension FocusedValues {
    var removeSelectedAction: FocusedAction<Void>? {
        get { self[RemoveSelectedActionKey.self] }
        set { self[RemoveSelectedActionKey.self] = newValue }
    }

    var pageActions: [FocusedAction<Void>]? {
        get { self[PageActionsKey.self] }
        set { self[PageActionsKey.self] = newValue }
    }
}

struct MainSidebar: View {
    @Binding var selection: Destination?
    /// Which places are still scanning, shown as a spinner on their row.
    @ObservedObject var activity: ScanActivity
    @EnvironmentObject private var release: BrimReleaseCheck
    @State private var hovered: Destination?
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Rows are buttons, and the selection is drawn here: an off-white
        // row with near-black text. A list selection is drawn by AppKit in
        // the accent, which Brim sets to Graphite, so it could only ever be
        // grey. Buttons expose as buttons, with the selected trait, so the
        // sidebar stays operable to VoiceOver; the arrow keys move through
        // it as a list's would.
        List {
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
        // A sidebar draws its symbols in the system accent, and the window's
        // own tint does not reach them: with a red accent every icon here
        // was red. Each row now colours its own symbol.
        .listItemTint(.fixed(Palette.snow))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { move(by: -1) }
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
            let isSelected = selection == destination
            Button {
                selection = destination
            } label: {
                HStack {
                    SidebarLabel(destination: destination, isSelected: isSelected)
                    Spacer()
                    // A fixed slot the spinner fades into. Inserted bare, it
                    // was laid out during the row's selection animation and
                    // drew stretched the first time a page was opened.
                    ZStack {
                        // Not on the selected row: the toolbar shows the page
                        // you are on working, and this spinner cannot be
                        // made dark, so on the off-white row it all but
                        // disappeared.
                        if activity.busy.contains(destination), !isSelected {
                            ProgressView()
                                .controlSize(.mini)
                                .fixedSize()
                                .transition(.opacity)
                                .accessibilityLabel("Checking")
                        }
                    }
                    .frame(width: 14, height: 14)
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Palette.snow : (hovered == destination ? Palette.selected : .clear))
                }
                // The selection and the hover wash fade rather than snap;
                // under Reduce Motion they change at once.
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isSelected)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered == destination)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                hovered = inside ? destination : (hovered == destination ? nil : hovered)
            }
            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .animation(.easeInOut(duration: 0.2), value: activity.busy.contains(destination))
        }
    }

    private func move(by step: Int) -> KeyPress.Result {
        let order = Destination.displayOrder
        guard let current = selection, let index = order.firstIndex(of: current) else { return .ignored }
        let next = index + step
        guard order.indices.contains(next) else { return .handled }
        selection = order[next]
        return .handled
    }
}

/// A sidebar row's label. Each icon once bounced, then turned, swung or
/// breathed, on every change of page, and Apple's guidance is to keep
/// motion off things people do constantly; what is left is one small press
/// when a page is chosen (`icon`).
private struct SidebarLabel: View {
    let destination: Destination
    let isSelected: Bool
    /// Counts arrivals at this page, so the icon answers each one once.
    @State private var arrivals = 0
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label {
            Text(destination.rawValue)
                .foregroundStyle(isSelected ? Palette.onSnow : Palette.ink)
                .fontWeight(isSelected ? .medium : .regular)
        } icon: {
            icon
        }
        .onChange(of: isSelected) { _, selected in
            if selected, !reduceMotion {
                arrivals += 1
            }
        }
    }

    /// A small press when the page is chosen: down a little, then settle
    /// without overshoot. It was taken out in a pass that trimmed motion,
    /// which left the sidebar feeling inert, and is back as it was.
    @ViewBuilder private var icon: some View {
        switch destination {
        case .home:
            // An app icon carries its own margin inside the square, so it
            // is drawn larger than a symbol to look the same size. It is an
            // image, not a symbol, so the same press is drawn by hand.
            BrimIcon(source: .bundle(Bundle.main.bundleURL), size: 22)
                .keyframeAnimator(initialValue: 1.0, trigger: arrivals) { content, scale in
                    content.scaleEffect(scale)
                } keyframes: { _ in
                    CubicKeyframe(0.9, duration: 0.1)
                    SpringKeyframe(1.0, duration: 0.3, spring: .smooth)
                }
        default:
            Image(systemName: destination.icon)
                .foregroundStyle(isSelected ? Palette.onSnow : Palette.snow)
                .symbolEffect(.bounce.down, options: .nonRepeating, value: arrivals)
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
                .foregroundStyle(Palette.ink)
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
