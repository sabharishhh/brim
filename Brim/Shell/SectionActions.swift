import BrimCore
import BrimUI
import SwiftUI

extension SectionModels {
    /// Opens a dropped application in Apps, or says it is not one Brim
    /// lists. Shared by Home's drop well and a drop anywhere on the window.
    func openApplication(from urls: [URL], shell: ShellState) -> Bool {
        guard let app = urls.first(where: { $0.pathExtension == "app" }) else { return false }
        shell.go(to: .apps, lens: .all)
        if !applications.selectApplication(at: app) {
            shell.show(ToastMessage(
                symbol: "questionmark.app",
                text: "\(app.deletingPathExtension().lastPathComponent) is not in the list"
            ))
        }
        return true
    }
}

extension LeftoverGroup {
    /// An owner row's icon (plan §9.1): the owner's saved icon once its app
    /// is gone, otherwise a monogram. Never Finder's folder, which would
    /// make every owner look the same.
    var ownerIcon: IconSource {
        IconResolver.source(
            for: IconSubject(name: displayName, kind: .folder, ownerName: displayName, ownerBundleID: identifier),
            remembered: { IconMemory.standard.has($0) }
        )
    }
}
