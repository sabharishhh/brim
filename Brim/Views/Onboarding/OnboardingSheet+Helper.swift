import SwiftUI

extension OnboardingSheet {
    var administratorNotice: some View {
        Text("macOS asks for an administrator password when you approve cleanup in protected system folders.")
            .font(.brimFacts)
            .foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
