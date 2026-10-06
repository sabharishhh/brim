import BrimCore
import BrimUI
import SwiftUI

extension SectionModels {
    /// Opens a dropped application in Apps, or looks inside an installer or
    /// an app that is not installed. Shared by Home's drop well, a drop
    /// anywhere on the window, and the Dock.
    func openApplication(from urls: [URL], shell: ShellState) -> Bool {
        if let installer = urls.first(where: { ["pkg", "mpkg", "dmg"].contains($0.pathExtension.lowercased()) }) {
            shell.lookInside(installer)
            return true
        }
        guard let app = urls.first(where: { $0.pathExtension == "app" }) else { return false }
        // An app that is installed opens in Apps. One that is not, still in
        // Downloads or on a disk image, is something about to be installed.
        // One in an Applications folder is installed even if the list has
        // not caught up with it yet.
        let installed = app.resolvingSymlinksInPath().pathComponents.contains("Applications")
        let selected = applications.selectApplication(at: app)
        if selected || installed {
            shell.go(to: .apps, lens: .all)
            if !selected {
                shell.show(ToastMessage(
                    symbol: "questionmark.app",
                    text: "\(app.deletingPathExtension().lastPathComponent) is not in the list"
                ))
            }
        } else {
            shell.lookInside(app)
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
