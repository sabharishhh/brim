import AppKit
import BrimUI
import SwiftUI

/// Shows items in Finder, selected, so the person can deal with what Brim
/// cannot. Several items open with all of them selected, one window for
/// each folder they are in.
struct RevealButton: View {
    let urls: [URL]
    var title: String?
    @State private var pressed = 0

    var body: some View {
        Button {
            pressed += 1
            Self.reveal(urls)
        } label: {
            if let title {
                Label(title, systemImage: "arrow.up.forward.app")
            } else {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
        }
        .symbolEffect(.bounce, value: pressed)
        .foregroundStyle(Palette.inkSecondary)
        .help(urls.count == 1 ? "Show in Finder" : "Show all in Finder")
        .accessibilityLabel(urls.count == 1 ? "Show in Finder" : "Show all in Finder")
    }

    static func reveal(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }
}
