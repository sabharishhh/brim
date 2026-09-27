import BrimUI
import SwiftUI

/// The menu items every row that stands for files carries: the three
/// things a Mac user expects of anything that is a file, in the order
/// Finder uses. A row adds its own (Keep, Add to Tray) after a divider.
struct ItemMenuItems: View {
    let urls: [URL]
    @Environment(ShellState.self) private var shell

    var body: some View {
        Button("Reveal in Finder") { shell.reveal(urls) }
        Button("Quick Look") { shell.quickLook(urls) }
        Button(urls.count == 1 ? "Copy Path" : "Copy Paths") { shell.copyPaths(urls) }
    }
}

extension View {
    /// Space opens Quick Look on the selection and closes it again, as in
    /// Finder. On the list rather than the menu, so a space typed into a
    /// search field is still a space.
    func quickLookOnSpace(_ urls: [URL], shell: ShellState) -> some View {
        onKeyPress(.space) {
            if shell.isPreviewing {
                shell.closePreview()
                return .handled
            }
            guard !urls.isEmpty else { return .ignored }
            shell.quickLook(urls)
            return .handled
        }
    }
}

// MARK: - Tray

/// What a section has picked to remove, offered to the window's Tray.
///
/// The section keeps the selection, and this only describes it, so there
/// is one reading of what is picked rather than a copy to keep in step.
/// Compares without the closures, for the same reason `FocusedAction`
/// does: a closure is never equal to the last one, and a preference that
/// always changes redraws the window forever.
struct TrayContents: Equatable {
    let count: Int
    let bytes: Int64
    let canReview: Bool
    /// Why Review is unavailable, or what to know first.
    var note: String?
    let review: () -> Void
    let clear: () -> Void

    static func == (lhs: TrayContents, rhs: TrayContents) -> Bool {
        (lhs.count, lhs.bytes, lhs.canReview, lhs.note) == (rhs.count, rhs.bytes, rhs.canReview, rhs.note)
    }
}

struct TrayKey: PreferenceKey {
    static let defaultValue: TrayContents? = nil

    static func reduce(value: inout TrayContents?, nextValue: () -> TrayContents?) {
        value = nextValue() ?? value
    }
}

extension View {
    func tray(_ contents: TrayContents?) -> some View {
        preference(key: TrayKey.self, value: contents)
    }
}

/// Undo for a change of what is picked, with redo, registered once per
/// change so ⌘Z steps back through them one at a time.
@MainActor
enum PickUndo {
    static func register(
        _ undoManager: UndoManager?, on model: LeftoversModel, name: String,
        from before: Set<String>, to after: Set<String>
    ) {
        guard before != after, let undoManager else { return }
        undoManager.registerUndo(withTarget: model) { model in
            MainActor.assumeIsolated {
                model.restoreSelection(before)
                register(undoManager, on: model, name: name, from: after, to: before)
            }
        }
        undoManager.setActionName(name)
    }
}
