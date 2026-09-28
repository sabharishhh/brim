import AppKit
import Observation

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

    /// An application dropped on the Dock icon opens in Apps, as a drop on
    /// the window does. Brim declares app bundles as a type it can view,
    /// ranked so it never becomes the default for opening one.
    func application(_: NSApplication, open urls: [URL]) {
        let apps = urls.filter { $0.pathExtension == "app" }
        guard !apps.isEmpty else { return }
        ExternalRequests.shared.send(.open(apps))
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
