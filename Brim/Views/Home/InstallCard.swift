import BrimCore
import BrimUI
import SwiftUI

/// Before an install: choose or drop an installer to look inside it, and
/// install from there. The recording around an install is Brim's own work
/// and never shows here.
struct InstallCard: View {
    @SwiftUI.Environment(ShellState.self) private var shell
    @State private var isTargeted = false

    var body: some View {
        // The same shape as the cards beside it: a heading, a line that
        // says what this is, and its actions along the bottom.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityHidden(true)
                Text("Installing")
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Before you install something")
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text("See what an installer adds before it changes your Mac")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button("Choose an Installer…") { shell.chooseInstaller() }
                .capsuleAction(prominent: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Palette.snow.opacity(isTargeted ? 0.6 : 0), lineWidth: 1.5)
        }
        .hoverLift()
        // An installer dropped here is looked inside, as anywhere on the
        // window; the outline says this card takes it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            shell.lookInside(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
