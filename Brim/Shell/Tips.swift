import SwiftUI
import TipKit

/// Shown at most once. TipKit retires a tip only when it is closed with its
/// own button, so doing what it describes also retires it
/// (`BrimTips.learned`).
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

    /// Once per launch, before any view asks for a tip. Skipped under tests,
    /// where a tip's popover would be a window nobody closes.
    static func configure() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        try? Tips.configure([.displayFrequency(.immediate)])
    }
}
