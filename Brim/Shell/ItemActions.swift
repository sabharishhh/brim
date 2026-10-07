import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// The menu items every row that stands for files carries: the three
/// things a Mac user expects of anything that is a file, in the order
/// Finder uses. A row adds its own (Keep, Add to Tray) after a divider.
struct ItemMenuItems: View {
    let urls: [URL]
    @SwiftUI.Environment(ShellState.self) private var shell

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

// MARK: - Put Back

extension ShellState {
    /// After a removal the check proved: says how much went, and offers it
    /// back while the Trash still holds it. Remnants and Background said
    /// this in two copies of the same function.
    func offerPutBack(
        planId: UUID, count: Int, noun: (one: String, many: String), service: any BrimServiceProtocol,
        afterPutBack: @escaping @MainActor () async -> Void
    ) {
        guard count > 0 else { return }
        Task { [weak self] in
            var toast = ToastMessage(
                symbol: "checkmark.circle.fill",
                text: count == 1 ? "Removed 1 \(noun.one)" : "Removed \(count) \(noun.many)"
            )
            if await (try? service.recoverableItems())?.contains(where: { $0.planId == planId }) == true {
                toast.actionTitle = "Put Back"
                toast.action = { [weak self] in
                    Task {
                        do {
                            try await service.undo(planId: planId)
                            await afterPutBack()
                        } catch {
                            self?.show(ToastMessage(
                                symbol: "exclamationmark.triangle.fill", text: "Could not put it back"
                            ))
                        }
                    }
                }
            }
            self?.show(toast)
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
