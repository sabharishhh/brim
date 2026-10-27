import AppKit
import BrimUI
import SwiftUI

/// Where the window can be: two short groups and the Journal. Updates is a
/// lens on Apps (`AppsLens`); Energy is under Your Mac.
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

    /// The order the person sees, and the only order anything may use: the menu
    /// once numbered from `allCases` and its shortcuts opened the wrong rows.
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

/// A command a view offers to the menu bar, equal to any other with the same
/// name. A bare closure never compares equal to the last one, so SwiftUI saw
/// every redraw as a focus change, rebuilt the menus and the window, and
/// kept the main thread at 100% while Brim was frontmost.
struct FocusedAction<Input>: Equatable {
    let name: String
    let perform: (Input) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name
    }
}

/// Lets a section offer "Remove Selected" to the Action menu. Defined here
/// because the section providing it may change.
struct RemoveSelectedActionKey: FocusedValueKey {
    typealias Value = FocusedAction<Void>
}

/// A page's toolbar commands, offered to the Action menu too, because a
/// toolbar can be hidden or customised.
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
        // Rows are buttons and the selection is drawn here, off-white with
        // near-black text, which an AppKit list selection in Brim's grey accent
        // cannot be. Buttons with the selected trait keep the sidebar usable with
        // VoiceOver, and the arrow keys move through it like a list.
        List {
            // Home carries Brim's own icon, so a header naming Brim repeated it.
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
        .scrollContentBackground(.hidden)
        .background { SidebarBackdrop().ignoresSafeArea() }
        // A sidebar draws its symbols in the system accent, out of the window
        // tint's reach, so each row colours its own.
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
                .buttonStyle(PointerButtonStyle(.plain))
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
                    // A fixed slot the spinner fades into; inserted bare, it drew stretched
                    // during the selection animation.
                    ZStack {
                        // Not on the selected row: the toolbar already shows that page working,
                        // and the spinner cannot be made dark for the off-white row.
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
            .buttonStyle(PointerButtonStyle(.plain))
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

/// A sidebar row's label. The chosen row's name grows a little, as in System
/// Settings, and nothing else moves.
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
                // 5.5% larger by scale, so the row's layout and the names below it do not
                // move. Only the size animates; changing weight as well looked like a
                // blink.
                .scaleEffect(isSelected ? 1.055 : 1, anchor: .leading)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: isSelected)
        } icon: {
            icon
        }
        .onChange(of: isSelected) { _, selected in
            if selected, !reduceMotion {
                arrivals += 1
            }
        }
    }

    /// Apps keeps its small press, which suits a grid of squares; the other
    /// icons stay still.
    @ViewBuilder private var icon: some View {
        switch destination {
        case .home:
            // An app icon carries its own margin inside the square, so it
            // is drawn larger than a symbol to look the same size.
            BrimIcon(source: .bundle(Bundle.main.bundleURL), size: 22)
        case .apps:
            Image(systemName: destination.icon)
                .foregroundStyle(isSelected ? Palette.onSnow : Palette.snow)
                .symbolEffect(.bounce.down, options: .nonRepeating, value: arrivals)
        default:
            Image(systemName: destination.icon)
                .foregroundStyle(isSelected ? Palette.onSnow : Palette.snow)
        }
    }
}

/// A newer Brim is on GitHub. Brim does not replace itself, so this opens
/// the release page.
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

/// The desktop showing through the sidebar, as in System Settings: AppKit's
/// sidebar material behind a wash of the canvas, so a bright wallpaper tints
/// rather than shows through. Dims when Brim is not frontmost, and Reduce
/// Transparency makes it solid.
private struct SidebarBackdrop: View {
    var body: some View {
        BehindWindowMaterial()
            .overlay(Palette.canvas.opacity(0.5))
            .accessibilityHidden(true)
    }
}

private struct BehindWindowMaterial: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}
