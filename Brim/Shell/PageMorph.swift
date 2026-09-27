import BrimCore
import BrimUI
import SwiftUI

/// The namespace page changes morph through: a Home tile's title becomes
/// the title of the page it opens, and Back reverses it.
extension EnvironmentValues {
    @Entry var pageNamespace: Namespace.ID?
}

extension View {
    /// Ties this view to the same element on another page. Nothing happens
    /// outside the window's namespace or under Reduce Motion, where a page
    /// change is a crossfade.
    func pageMorph(_ id: String) -> some View {
        modifier(PageMorph(id: id))
    }
}

private struct PageMorph: ViewModifier {
    let id: String
    @SwiftUI.Environment(\.pageNamespace) private var namespace
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let namespace, !reduceMotion {
            content.matchedGeometryEffect(id: id, in: namespace, properties: .position)
        } else {
            content
        }
    }
}

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
