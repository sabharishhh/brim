import AppKit
import BrimPrivileged
import Observation
import SwiftUI

/// Something asked of Brim from outside its window: the Dock, a Shortcut,
/// Spotlight. Held here until a window can answer it, because the request
/// often arrives while Brim is still launching.
@MainActor
@Observable
final class ExternalRequests {
    enum Request: Equatable {
        /// Applications dropped on the Dock icon, to inspect.
        case open([URL])
        /// The review for one app. Nothing is approved from outside.
        case remove(URL)
        case show(Destination)
        case check
    }

    static let shared = ExternalRequests()

    private(set) var pending: [Request] = []

    func send(_ request: Request) {
        pending.append(request)
        NSApp.activate()
    }

    /// Everything waiting, once.
    func drain() -> [Request] {
        defer { pending.removeAll() }
        return pending
    }
}

/// The Dock: its menu, and applications dropped on its icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Brim is dark whatever the system is set to. Set on the application
    /// before any window exists, so every window, sheet, menu and alert,
    /// Settings included, is drawn dark from its first frame.
    func applicationWillFinishLaunching(_: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    /// SwiftUI refuses to quit while a sheet is open, without asking this
    /// delegate: with an installer's preview up, Quit in the menu, the Dock
    /// and a script all did nothing. Brim takes Quit first, asks its sheets
    /// to close (a removal that is running keeps its sheet, and so keeps
    /// Brim open), then quits.
    func applicationDidFinishLaunching(_: Notification) {
        let quit = NSApp.mainMenu?.items.first?.submenu?.items.first {
            $0.action == #selector(NSApplication.terminate(_:))
        }
        quit?.target = self
        quit?.action = #selector(quitFromMenu(_:))
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(quitRequested(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication)
        )
    }

    @objc private func quitFromMenu(_: Any?) {
        QuitRequest.shared.quit()
    }

    @objc private func quitRequested(_: NSAppleEventDescriptor, reply _: NSAppleEventDescriptor) {
        QuitRequest.shared.quit()
    }

    func applicationWillTerminate(_: Notification) {
        PrivilegedHelperClient.stopAll()
    }

    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for destination in [Destination.home, .apps, .leftovers] {
            let item = NSMenuItem(title: destination.rawValue, action: #selector(open(_:)), keyEquivalent: "")
            item.representedObject = destination.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let check = NSMenuItem(title: "Check Again", action: #selector(checkAgain), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        return menu
    }

    /// An application or installer dropped on the Dock icon, or opened
    /// with Brim from Finder, is handled as a drop on the window is. Brim
    /// declares these as types it can view, ranked so it never becomes the
    /// default for opening one.
    func application(_: NSApplication, open urls: [URL]) {
        let opened = urls.filter { ["app", "pkg", "mpkg", "dmg"].contains($0.pathExtension.lowercased()) }
        guard !opened.isEmpty else { return }
        ExternalRequests.shared.send(.open(opened))
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let destination = Destination(rawValue: raw) else {
            return
        }
        ExternalRequests.shared.send(.show(destination))
    }

    @objc private func checkAgain() {
        ExternalRequests.shared.send(.check)
    }
}

/// Quit, asked of the sheets first. Closing a sheet from AppKit does not
/// work: SwiftUI puts it straight back, because its own state still says
/// it is shown. So each sheet closes itself (`closesForQuit`).
@MainActor
@Observable
final class QuitRequest {
    static let shared = QuitRequest()

    private(set) var isQuitting = false

    func quit() {
        isQuitting = true
        Task {
            // A sheet takes a moment to animate away.
            for _ in 0 ..< 20 where NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            NSApp.terminate(nil)
            // Still here: a sheet would not close.
            isQuitting = false
        }
    }
}

extension View {
    /// Closes this sheet when Brim is quitting, unless `keepOpen`.
    func closesForQuit(keepOpen: Bool = false) -> some View {
        modifier(ClosesForQuit(keepOpen: keepOpen))
    }
}

private struct ClosesForQuit: ViewModifier {
    let keepOpen: Bool
    @SwiftUI.Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.onChange(of: QuitRequest.shared.isQuitting) { _, quitting in
            if quitting, !keepOpen {
                dismiss()
            }
        }
    }
}
