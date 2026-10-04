import AppKit
import Observation
import SwiftUI

/// What the window's chrome knows: where it is, where it has been, what
/// Quick Look is showing, and the note at the bottom.
///
/// One object, handed to the menu bar as a focused value. That is safe
/// where a closure was not (`FocusedAction`): the reference never changes,
/// so the scene never sees a new value and never rebuilds its menus for
/// nothing. It compares by identity for exactly that reason.
@MainActor
@Observable
final class ShellState: Equatable {
    private(set) var selection: Destination = .home
    var appsLens: AppsLens = .all
    /// The last page change came from the keyboard: arrow keys in the
    /// sidebar, a Command-digit or Back and Forward from the menu. Those are
    /// immediate; only a change made with the pointer fades.
    private(set) var navigatedByKeyboard = false
    private var back: [Destination] = []
    private var forward: [Destination] = []

    var previewURL: URL?
    private(set) var previewURLs: [URL] = []

    /// Bumped by Check Again, which the window answers by reading the
    /// current page again. A counter, so asking twice is two checks.
    private(set) var checkRequests = 0

    private(set) var toast: ToastMessage?
    private var toastDismissal: Task<Void, Never>?

    /// The ⌘K panel.
    var showsCommandBar = false
    /// An app whose removal was asked for from outside the window, by a
    /// Shortcut or Spotlight. Apps opens its review and clears this. The
    /// review is all it opens: approval still comes from this window.
    var pendingRemoval: URL?

    nonisolated static func == (lhs: ShellState, rhs: ShellState) -> Bool {
        lhs === rhs
    }

    // MARK: - Navigation

    var canGoBack: Bool {
        !back.isEmpty
    }

    var canGoForward: Bool {
        !forward.isEmpty
    }

    func go(to destination: Destination, lens: AppsLens? = nil) {
        if let lens {
            appsLens = lens
        }
        guard destination != selection else { return }
        back.append(selection)
        forward.removeAll()
        move(to: destination)
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(selection)
        move(to: previous)
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(selection)
        move(to: next)
    }

    /// Restoring a saved window: no history, and nothing to animate from.
    func restore(_ destination: Destination) {
        selection = destination
    }

    private func move(to destination: Destination) {
        // A preview belongs to the page that asked for it.
        previewURL = nil
        navigatedByKeyboard = NSApp.currentEvent?.type == .keyDown
        selection = destination
    }

    func requestCheck() {
        checkRequests += 1
    }

    // MARK: - Items

    var isPreviewing: Bool {
        previewURL != nil
    }

    func closePreview() {
        previewURL = nil
    }

    func quickLook(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let first = existing.first else { return }
        previewURLs = existing
        previewURL = first
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// A folder opens as a Finder window of what is inside it; anything
    /// else, an app bundle included, is revealed selected. `open` is never
    /// used here, because on an app or a document it would launch it.
    func showInFinder(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        } else {
            reveal([url])
        }
    }

    func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        let text = urls.count == 1 ? "Copied the path" : "Copied \(urls.count) paths"
        show(ToastMessage(symbol: "doc.on.doc", text: text))
    }

    // MARK: - Toast

    /// Shows a note for a few seconds, replacing any already showing.
    func show(_ message: ToastMessage) {
        toast = message
        toastDismissal?.cancel()
        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(message.action == nil ? 3 : 6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastDismissal?.cancel()
        toast = nil
    }
}

/// A short note about something that just happened, with at most one way
/// to take it back.
struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let symbol: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool {
        lhs.id == rhs.id
    }
}

struct ShellStateKey: FocusedValueKey {
    typealias Value = ShellState
}

/// The items the focused section has selected, for Reveal in Finder, Copy
/// Path and Quick Look in the menu bar. A value, so it compares.
struct SelectedItems: Equatable {
    let urls: [URL]
}

struct SelectedItemsKey: FocusedValueKey {
    typealias Value = SelectedItems
}

extension FocusedValues {
    var shell: ShellState? {
        get { self[ShellStateKey.self] }
        set { self[ShellStateKey.self] = newValue }
    }

    var selectedItems: SelectedItems? {
        get { self[SelectedItemsKey.self] }
        set { self[SelectedItemsKey.self] = newValue }
    }
}
