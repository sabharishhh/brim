import SwiftUI
import TipKit

/// The three things worth learning once, each shown once and never again
/// (plan §14).
///
/// TipKit only retires a tip that is closed with its own button, so a tip
/// left open came back every time its panel or the Tray appeared, launch
/// after launch. Each is now shown at most once, and doing the thing it
/// describes retires it at once (`BrimTips.learned`).
struct DropAppTip: Tip {
    var options: [any TipOption] {
        [MaxDisplayCount(1)]
    }

    var title: Text {
        Text("The Dock icon works too")
    }

    var message: Text? {
        Text("Drop an app on it to open its page")
    }

    var image: Image? {
        Image(systemName: "arrow.down.app")
    }
}

struct KeepTip: Tip {
    var options: [any TipOption] {
        [MaxDisplayCount(1)]
    }

    var title: Text {
        Text("Keep what you need")
    }

    var message: Text? {
        Text("Kept items stay out of the list")
    }

    var image: Image? {
        Image(systemName: "pin")
    }
}

struct TrayTip: Tip {
    var options: [any TipOption] {
        [MaxDisplayCount(1)]
    }

    var title: Text {
        Text("Review when ready")
    }

    var message: Text? {
        Text("Nothing is removed until you press Remove")
    }

    var image: Image? {
        Image(systemName: "tray.full")
    }
}

enum BrimTips {
    /// The person did what a tip explains, so it has nothing left to say.
    static func learned(_ tip: some Tip) {
        tip.invalidate(reason: .actionPerformed)
    }

    /// Once per launch, before any view asks for a tip. Not under a test
    /// run, where a tip's popover would be a window nobody closes.
    static func configure() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        try? Tips.configure([.displayFrequency(.immediate)])
    }
}
