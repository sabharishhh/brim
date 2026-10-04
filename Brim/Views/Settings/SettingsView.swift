import BrimCore
import BrimUI
import SwiftUI

/// Brim's Settings window: the Dock, what Brim can read, and what it keeps
/// about the person's use of it.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Access", systemImage: "lock.shield") { AccessSettings() }
            Tab("Privacy", systemImage: "hand.raised") { PrivacySettings() }
        }
        .frame(width: 480)
    }
}

/// Keys shared between Settings and the window.
enum SettingsKey {
    /// A count of new leftovers on the Dock icon. Off unless asked for:
    /// a badge that is always there is a badge nobody reads.
    static let dockBadge = "dock.showsNewLeftovers"
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.dockBadge) private var showsDockBadge = false

    var body: some View {
        Form {
            Toggle("Show removed apps that left something on the Dock icon", isOn: $showsDockBadge)
            Text("Clears when you open Leftovers")
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
        .formStyle(.grouped)
        // As tall as what is in it, not a window of empty grey.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AccessSettings: View {
    @StateObject private var access = FullDiskAccessModel()

    var body: some View {
        Form {
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
            } footer: {
                Text("Lets Brim read containers and login items")
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Section {
                Text("macOS requests an administrator password for protected cleanup.")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .formStyle(.grouped)
        // As tall as what is in it, not a window of empty grey.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            access.startObserving()
        }
        .onDisappear { access.stopObserving() }
    }
}

private struct PrivacySettings: View {
    @SwiftUI.Environment(AppSession.self) private var session
    @State private var icons: (count: Int, bytes: Int64) = (0, 0)
    @State private var confirmsIcons = false
    @State private var confirmsKept = false

    var body: some View {
        Form {
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
            } footer: {
                Text("Stored only on this Mac, and removed with Brim")
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .formStyle(.grouped)
        // As tall as what is in it, not a window of empty grey.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
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
