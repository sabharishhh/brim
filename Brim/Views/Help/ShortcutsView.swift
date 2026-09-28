import SwiftUI

/// Every keyboard shortcut, under Help (plan §14).
struct ShortcutsView: View {
    private struct Shortcut: Identifiable {
        let keys: String
        let action: String
        var id: String {
            keys + action
        }
    }

    private let sections: [(title: String, items: [Shortcut])] = [
        ("Moving around", [
            Shortcut(keys: "⌘1 to ⌘7", action: "Go to a page"),
            Shortcut(keys: "⌘[  ⌘]", action: "Back and forward"),
            Shortcut(keys: "⌘K", action: "Go to, or find anything"),
            Shortcut(keys: "↑ ↓", action: "Move through a list")
        ]),
        ("Looking", [
            Shortcut(keys: "Space  ⌘Y", action: "Quick Look"),
            Shortcut(keys: "⌥⌘R", action: "Reveal in Finder"),
            Shortcut(keys: "⌥⌘C", action: "Copy path"),
            Shortcut(keys: "⌘R", action: "Check again")
        ]),
        ("Removing", [
            Shortcut(keys: "⌘⌫", action: "Review what is in the Tray"),
            Shortcut(keys: "⌘Z", action: "Undo a keep or a change to the Tray"),
            Shortcut(keys: "Esc", action: "Close a review")
        ])
    ]

    var body: some View {
        Form {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.items) { shortcut in
                        LabeledContent(shortcut.action) {
                            Text(shortcut.keys)
                                .font(.body.monospaced())
                                .foregroundStyle(Palette.inkSecondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Help's menu item, as a view so it can reach `openWindow`.
struct ShortcutsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Keyboard Shortcuts") { openWindow(id: ShortcutsView.windowID) }
            .keyboardShortcut("/", modifiers: .command)
    }
}

extension ShortcutsView {
    static let windowID = "shortcuts"
}
