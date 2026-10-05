import BrimCore
import BrimPrivileged
import BrimUI
import SwiftUI

/// Brim's few settings in one pane, and Feedback beside them.
///
/// General, Access and Privacy were three tabs holding one or two rows each,
/// so most of a click was spent finding the row. As sections of one pane they
/// read at a glance, and the window opens on whichever tab was used last.
struct SettingsView: View {
    @AppStorage("settings.tab") private var selection = SettingsTab.general

    var body: some View {
        TabView(selection: $selection) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings() }
            Tab("Feedback", systemImage: "bubble.left.and.bubble.right", value: .feedback) { FeedbackSettingsView() }
        }
        .frame(width: 640, height: selection == .feedback ? 400 : nil)
    }
}

private enum SettingsTab: String {
    case general, feedback
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

    var body: some View {
        Section {
            LabeledContent("Full Disk Access") {
                HStack(spacing: 10) {
                    StatusDot(status: access.isGranted ? .clear : .attention)
                    Text(access.isGranted ? "On" : "Off")
                    if !access.isGranted {
                        Button("Open Settings") { access.requestAccess() }
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
            Text("Deleted permanently, not moved to the Trash")
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
