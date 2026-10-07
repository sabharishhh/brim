import BrimCore
import BrimPrivileged
import BrimUI
import SwiftUI

/// Brim's few settings in one pane, and Feedback beside them.
///
/// General, Access and Privacy were three tabs holding one or two rows each,
/// so most of a click was spent finding the row. As sections of one pane they
/// read at a glance, and the window opens on whichever tab was used last.
///
/// The two tabs are drawn here rather than by a `TabView`. AppKit draws a
/// settings toolbar's icons in the system accent, so with a red accent they
/// were red, and the closest Brim can set for itself is Graphite, which made
/// them a dull grey beside the off-white of everything else. The selected
/// tab is told apart by colour alone: off-white, with the other dimmer.
struct SettingsView: View {
    @AppStorage("settings.tab") private var selection = SettingsTab.general

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 8)
            Divider()
            switch selection {
            case .general: GeneralSettings()
            case .feedback: FeedbackSettingsView()
            }
        }
        .navigationTitle(selection.title)
        .frame(width: 640, height: selection == .feedback ? 440 : nil)
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 18))
                    .frame(height: 22)
                Text(tab.title)
                    .font(.caption)
            }
            .foregroundStyle(isSelected ? Palette.snow : Palette.inkTertiary)
            .frame(width: 72, height: 50)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private enum SettingsTab: String, CaseIterable {
    case general, feedback

    var title: String {
        switch self {
        case .general: "General"
        case .feedback: "Feedback"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .feedback: "bubble.left.and.bubble.right"
        }
    }
}

/// Keys shared between Settings and the window.
enum SettingsKey {
    /// A count of new leftovers on the Dock icon. Off unless asked for:
    /// a badge that is always there is a badge nobody reads.
    static let dockBadge = "dock.showsNewLeftovers"
}

private struct GeneralSettings: View {
    var body: some View {
        Form {
            DockSection()
            AccessSection()
            IntelligenceSection()
            PrivacySection()
            RemoveBrimSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        // As tall as what is in it, not a window of empty grey.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DockSection: View {
    @AppStorage(SettingsKey.dockBadge) private var showsDockBadge = false

    var body: some View {
        Section {
            Toggle("Show removed apps that left something on the Dock icon", isOn: $showsDockBadge)
                // A Form lays the label out beside the switch, and the
                // switch alone exposed no name.
                .accessibilityLabel("Show removed apps that left something on the Dock icon")
        } header: {
            Text("Dock")
        } footer: {
            Text("Clears when you open Remnants")
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
    }
}

private struct AccessSection: View {
    @StateObject private var access = FullDiskAccessModel()
    @AppStorage(FullDiskAccess.requestedKey) private var accessRequestedAt = 0.0

    var body: some View {
        Section {
            LabeledContent("Full Disk Access") {
                HStack(spacing: 10) {
                    StatusDot(status: access.isGranted ? .clear : .attention)
                    Text(access.isGranted ? "On" : "Off")
                    if !access.isGranted {
                        // Asked from here, so a reopen comes back to here.
                        let offer = AccessOffer.current(requestedAt: accessRequestedAt, from: .settings)
                        Button(offer.title, action: offer.action)
                    }
                }
            }
        } header: {
            Text("Access")
        } footer: {
            Text("Lets Brim read containers and login items. macOS asks for an administrator "
                + "password before protected cleanup.")
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
        .onAppear {
            access.startObserving()
        }
        .onDisappear { access.stopObserving() }
    }
}

/// The way out, where people look for it: Brim removes itself and everything
/// it wrote, and nothing is left on the Mac or in the Trash.
private struct RemoveBrimSection: View {
    @StateObject private var helper = PrivilegedHelperClient()
    @State private var confirms = false
    @State private var problem: String?

    var body: some View {
        Section {
            LabeledContent("Remove Brim and everything it keeps") {
                Button("Remove Brim…", role: .destructive) { confirms = true }
            }
        } footer: {
            Text("Deleted permanently. Nothing goes to the Trash.")
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
        .alert(SelfRemoval.confirmationTitle, isPresented: $confirms) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Brim", role: .destructive) {
                Task { problem = await SelfRemoval.perform(helper: helper) }
            }
        } message: {
            Text(SelfRemoval.confirmationMessage)
        }
        .alert("Brim has not removed itself", isPresented: showsProblem) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private var showsProblem: Binding<Bool> {
        Binding(get: { problem != nil }, set: { shown in
            if !shown {
                problem = nil
            }
        })
    }
}

private struct PrivacySection: View {
    @SwiftUI.Environment(AppSession.self) private var session
    @State private var icons: (count: Int, bytes: Int64) = (0, 0)
    @State private var confirmsIcons = false
    @State private var confirmsKept = false

    var body: some View {
        Section {
            LabeledContent("Saved app icons") {
                HStack(spacing: 10) {
                    Text(icons.count == 0 ? "None" : "\(icons.count) · \(ByteText.short(icons.bytes))")
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                    Button("Clear") { confirmsIcons = true }
                        .disabled(icons.count == 0)
                }
            }
            LabeledContent("Kept items") {
                HStack(spacing: 10) {
                    Text(session.decisions.kept.isEmpty ? "None" : "\(session.decisions.kept.count)")
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                    Button("Forget") { confirmsKept = true }
                        .disabled(session.decisions.kept.isEmpty)
                }
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Stored only on this Mac, and removed with Brim")
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
        .task { icons = session.icons.footprint() }
        .confirmationDialog("Clear saved icons?", isPresented: $confirmsIcons) {
            Button("Clear Icons", role: .destructive) {
                session.icons.forgetAll()
                icons = session.icons.footprint()
            }
        } message: {
            Text("Removed apps will show a monogram instead")
        }
        .confirmationDialog("Forget kept items?", isPresented: $confirmsKept) {
            Button("Forget", role: .destructive) { session.decisions.forgetAll() }
        } message: {
            Text("They return to the list on the next check")
        }
    }
}
