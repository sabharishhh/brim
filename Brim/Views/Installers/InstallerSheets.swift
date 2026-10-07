import BrimCore
import BrimUI
import SwiftUI

/// The window's installer sheet, a look inside an installer, and what the
/// recording around an install has to say. Also picks up a recording left
/// open when Brim last quit.
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
                    .closesForQuit()
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
            .task { await model.load(service: service) }
            // Compositor was missing from Apps after Brim installed it: the
            // list had been read before it existed, and nothing read it again.
            .onChange(of: shell.installs) { Task { await applications.load(service: service) } }
            // A package's app arrives through Installer, not Brim; Apps
            // reads the list again once the recording around it is kept.
            .onChange(of: model.keptQuietly) { _, kept in
                guard kept != nil else { return }
                shell.noteInstall()
                model.keptQuietly = nil
            }
            // An install that put nothing down, said once rather than kept
            // in a property nobody showed.
            .onChange(of: model.notice) { _, notice in
                guard let notice else { return }
                shell.show(ToastMessage(symbol: "info.circle", text: notice))
                model.notice = nil
            }
    }
}
