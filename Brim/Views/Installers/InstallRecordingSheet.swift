import BrimCore
import BrimUI
import SwiftUI

/// What a recording found, for the person to keep or not.
///
/// What is linked to the install by name, developer or registration starts
/// ticked. What only appeared while recording starts unticked: anything
/// else running wrote too, and only the person knows what they installed.
struct InstallRecordingSheet: View {
    let result: InstallRecordingResult
    @ObservedObject var model: InstallRecordingModel
    @State private var apps: Set<String>
    @State private var items: Set<String>
    @State private var isKeeping = false

    init(result: InstallRecordingResult, model: InstallRecordingModel) {
        self.result = result
        self.model = model
        // An app that only updated itself while recording is not what was
        // installed, unless nothing new appeared at all.
        let fresh = result.apps.filter { !$0.wasUpdated }
        _apps = State(initialValue: Set((fresh.isEmpty ? result.apps : fresh).map(\.id)))
        _items = State(initialValue: Set(result.linked.map(\.id)))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if result.apps.isEmpty {
                        Text("No app appeared. Install and open it, then finish again.")
                            .font(.brimFacts)
                            .foregroundStyle(Palette.inkSecondary)
                    } else {
                        appsSection
                        if !result.linked.isEmpty {
                            itemSection("Linked to the install", result.linked)
                        }
                        if !result.unclaimed.isEmpty {
                            itemSection("Appeared while recording", result.unclaimed)
                        }
                        if result.linked.isEmpty, result.unclaimed.isEmpty {
                            Text("Nothing else appeared yet")
                                .font(.brimFacts)
                                .foregroundStyle(Palette.inkSecondary)
                        }
                    }
                    notes
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            footer
        }
        .frame(width: 620, height: 660)
        .interactiveDismissDisabled()
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.brimPageTitle)
                .foregroundStyle(Palette.ink)
            Text("Recorded \(Self.time.format(result.startedAt)) to \(Self.time.format(result.endedAt))")
                .font(.brimFacts)
                .foregroundStyle(Palette.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        guard let first = result.apps.first else { return "Nothing installed yet" }
        return result.apps.count == 1 ? "What installing \(first.name) created" : "What this install created"
    }

    private var appsSection: some View {
        InstallerSection(title: "Apps", count: result.apps.count) {
            ForEach(result.apps) { app in
                Toggle(isOn: binding(app.id, in: $apps)) {
                    rowLabel(
                        title: [app.name, app.version].compactMap(\.self).joined(separator: " "),
                        detail: app.path, note: app.wasUpdated ? "Updated" : "New"
                    )
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func itemSection(_ title: String, _ list: [RecordedItem]) -> some View {
        InstallerSection(title: title, count: list.count) {
            ForEach(list) { item in
                Toggle(isOn: binding(item.id, in: $items)) {
                    rowLabel(
                        title: item.isRegistration ? item.path : (item.path as NSString).lastPathComponent,
                        detail: item.isRegistration ? item.why : item.path,
                        // Under "Appeared while recording", saying so again
                        // on every row said nothing.
                        note: item.isRegistration || item.app == nil ? nil : item.why
                    )
                }
                .toggleStyle(.checkbox)
                .disabled(item.app.map { !apps.contains($0) } ?? false)
            }
        }
    }

    private func rowLabel(title: String, detail: String, note: String?) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if let note {
                Text(note)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var notes: some View {
        let others = result.otherApps.values.reduce(0, +)
        VStack(alignment: .leading, spacing: 4) {
            if others > 0 {
                Text(others == 1 ? "1 item named for another app is left out."
                    : "\(others) items named for other apps are left out.")
            }
            if !result.unreadable.isEmpty {
                Text(result.unreadable.count == 1 ? "1 place could not be read."
                    : "\(result.unreadable.count) places could not be read.")
            }
            if !result.apps.isEmpty {
                Text("Brim uses what you keep when this app is removed.")
            }
        }
        .font(.caption)
        .foregroundStyle(Palette.inkTertiary)
    }

    private var footer: some View {
        HStack {
            Button("Discard") { Task { await model.cancel() } }
                .capsuleAction()
            Spacer()
            Button("Keep Recording") { model.keepRecording() }
                .capsuleAction()
                .help("Go back to recording, and finish again later")
            if !result.apps.isEmpty {
                Button("Keep") {
                    isKeeping = true
                    Task {
                        _ = await model.keep(result, apps: apps, items: items)
                        isKeeping = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .capsuleAction(prominent: true)
                .disabled(apps.isEmpty || isKeeping)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func binding(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) }, set: { isOn in
            if isOn {
                set.wrappedValue.insert(id)
            } else {
                set.wrappedValue.remove(id)
            }
        })
    }

    private static let time = Date.FormatStyle.dateTime.hour().minute()
}

/// The window's installer sheets: a look inside an installer, and a
/// recording's result. Also answers the menu bar, and picks up a recording
/// left open when Brim last quit.
struct InstallerSheets: ViewModifier {
    @ObservedObject var model: InstallRecordingModel
    @Bindable var shell: ShellState
    let applications: ApplicationsModel
    @SwiftUI.Environment(\.brimService) private var service

    func body(content: Content) -> some View {
        content
            .sheet(item: $shell.installerToRead) { request in
                InstallerPreviewSheet(request: request, recording: model)
                    .environment(shell)
            }
            .sheet(isPresented: Binding(get: { isShowingResult }, set: { shown in
                // Closed some other way than its buttons: the recording
                // stays open rather than being lost.
                if !shown, isShowingResult {
                    model.keepRecording()
                }
            })) {
                if case let .found(result) = model.phase {
                    InstallRecordingSheet(result: result, model: model)
                }
            }
            .alert("Could not record the install", isPresented: Binding(
                get: { model.problem != nil }, set: {
                    if !$0 {
                        model.problem = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.problem ?? "")
            }
            .modifier(InstallNotes(model: model, shell: shell))
            .task { await model.load(service: service) }
            // Compositor was missing from Apps after Brim installed it: the
            // list had been read before it existed, and nothing read it again.
            .onChange(of: shell.installs) { Task { await applications.load(service: service) } }
            .onChange(of: model.isRecording, initial: true) { _, recording in
                shell.isRecordingInstall = recording
            }
            .onChange(of: shell.recordingRequests) {
                Task {
                    if model.isRecording {
                        await model.finish()
                    } else {
                        await model.start(service: service)
                    }
                }
            }
    }

    private var isShowingResult: Bool {
        if case .found = model.phase {
            return true
        }
        return false
    }
}

/// What an install Brim performed says afterwards: whether to move the
/// installer to the Trash, and a note when a recording was kept or there
/// was nothing to record.
private struct InstallNotes: ViewModifier {
    @ObservedObject var model: InstallRecordingModel
    let shell: ShellState

    func body(content: Content) -> some View {
        content
            .alert(trashTitle, isPresented: Binding(
                get: { model.installerToTrash != nil }, set: {
                    if !$0 {
                        model.installerToTrash = nil
                    }
                }
            )) {
                Button("Move to Trash") {
                    if let url = model.installerToTrash {
                        moveToTrash(url)
                    }
                }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("What it installed is in place, so the installer is no longer needed.")
            }
            .onChange(of: model.keptQuietly) { _, kept in
                guard let kept else { return }
                // A package's app arrives through Installer, not Brim.
                shell.noteInstall()
                let count = kept.items.count
                let name = kept.apps.first?.name ?? "the app"
                shell.show(ToastMessage(symbol: "checkmark.circle", text: count == 1
                        ? "Noted what installing \(name) created: 1 item"
                        : "Noted what installing \(name) created: \(count) items"))
                model.keptQuietly = nil
            }
            .onChange(of: model.notice) { _, notice in
                guard let notice else { return }
                shell.show(ToastMessage(symbol: "info.circle", text: notice))
                model.notice = nil
            }
    }

    private var trashTitle: String {
        "Move \u{201C}\(model.installerToTrash?.lastPathComponent ?? "")\u{201D} to the Trash?"
    }

    private func moveToTrash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            model.problem = error.localizedDescription
        }
    }
}
