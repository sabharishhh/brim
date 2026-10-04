import BrimUI
import SwiftUI

/// A small icon button that appears on a row: one size and one hit area
/// everywhere, so a row of them lines up and each is easy to hit.
struct RowAction: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Palette.inkSecondary)
        .help(help)
        .accessibilityLabel(help)
    }
}
