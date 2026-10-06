import BrimUI
import SwiftUI

/// The menu items every row that stands for files carries: the three
/// things a Mac user expects of anything that is a file, in the order
/// Finder uses. A row adds its own (Keep, Add to Tray) after a divider.
struct ItemMenuItems: View {
    let urls: [URL]
    @Environment(ShellState.self) private var shell

    var body: some View {
        Button("Show in Finder") { shell.reveal(urls) }
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

/// What a page has picked to remove, drawn as its Tray.
///
/// The page keeps the selection, and this only describes it, so there is
/// one reading of what is picked rather than a copy to keep in step.
/// Compares without the closures, for the same reason `FocusedAction`
/// does: a closure is never equal to the last one.
struct TrayContents: Equatable {
    let count: Int
    let bytes: Int64?
    let canReview: Bool
    /// Why Review is unavailable, or what to know first.
    var note: String?
    let review: () -> Void
    let clear: () -> Void

    static func == (lhs: TrayContents, rhs: TrayContents) -> Bool {
        (lhs.count, lhs.bytes, lhs.canReview, lhs.note) == (rhs.count, rhs.bytes, rhs.canReview, rhs.note)
    }
}
