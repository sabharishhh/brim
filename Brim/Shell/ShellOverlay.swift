import SwiftUI

/// The Tray and the toast, floating at the bottom of the page.
///
/// A safe area inset rather than an overlay, so the last rows of a list
/// scroll up clear of the glass instead of sitting under it.
struct ShellOverlay: View {
    let tray: TrayContents?
    @Environment(ShellState.self) private var shell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            if let toast = shell.toast {
                Toast(
                    symbol: toast.symbol, message: toast.text, actionTitle: toast.actionTitle,
                    action: toast.action.map { action in
                        {
                            action()
                            shell.dismissToast()
                        }
                    }
                )
                .id(toast.id)
                .transition(.floating(arrival: Motion.toastArrive, reduceMotion: reduceMotion))
            }
            if let tray {
                VStack(spacing: 6) {
                    if let note = tray.note {
                        Label(note, systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(Palette.caution)
                    }
                    TrayBar(
                        count: tray.count, bytes: tray.bytes, canReview: tray.canReview,
                        review: tray.review, clear: tray.clear
                    )
                }
                .transition(.floating(arrival: Motion.trayArrive, reduceMotion: reduceMotion))
            }
        }
        .padding(.bottom, tray == nil && shell.toast == nil ? 0 : 14)
        .frame(maxWidth: .infinity)
        // The transitions carry their own timing: 180 ms in for a toast,
        // 220 ms for the tray, 120 ms out for both. These only make the
        // change animated at all.
        .animation(Motion.resolved(Motion.trayArrive, reduceMotion: reduceMotion), value: tray == nil)
        .animation(Motion.resolved(Motion.toastArrive, reduceMotion: reduceMotion), value: shell.toast)
    }
}
