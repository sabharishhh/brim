import BrimUI
import SwiftUI

/// About Brim: the character, the version and where the project lives.
struct AboutView: View {
    static let windowID = "about"

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    var body: some View {
        VStack(spacing: 10) {
            CharacterArtwork(size: 64)
            Text("Brim")
                .font(.brimPageTitle)
                .foregroundStyle(Palette.ink)
            Text(version)
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkSecondary)
                .selectableText()
            Text("See what apps leave behind,\nand make sure it’s gone.")
                .font(.brimFacts)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            // A capsule like every other link; as plain text it took the system blue.
            Link("Brim on GitHub", destination: URL(string: "https://github.com/sabharishhh/brim")!)
                .capsuleAction()
                .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(width: 320)
        .background(Palette.canvas)
    }
}

/// Opens the About window from the app menu.
struct AboutMenuItem: View {
    @SwiftUI.Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Brim") { openWindow(id: AboutView.windowID) }
    }
}
