import BrimUI
import SwiftUI

/// About Brim: the character, the version, and where the project lives.
/// The standard panel showed a flat icon and nothing of what Brim does.
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
                .textSelection(.enabled)
            Text("Shows what software left on this Mac, and checks it is gone when you remove it.")
                .font(.brimFacts)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            Link("Brim on GitHub", destination: URL(string: "https://github.com/sabharishhh/brim")!)
                .font(.brimFacts)
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
