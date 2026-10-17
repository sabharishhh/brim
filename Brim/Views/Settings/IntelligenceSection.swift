import BrimUI
import SwiftUI

/// Whether Brim uses the on-device model, and whether the Mac can. Nothing
/// leaves the Mac either way.
struct IntelligenceSection: View {
    @AppStorage(SystemLanguageReader.enabledKey) private var isEnabled = true
    @SwiftUI.Environment(\.intelligence) private var intelligence
    @State private var availability: ModelAvailability?

    var body: some View {
        Section {
            Toggle("Summarise release notes and installer scripts", isOn: $isEnabled)
                .accessibilityLabel("Summarise release notes and installer scripts")
            LabeledContent("Apple Intelligence") {
                Text(availability?.phrase ?? "Checking")
                    .foregroundStyle(Palette.inkSecondary)
            }
        } header: {
            Text("Apple Intelligence")
        } footer: {
            Text("Runs on this Mac. Nothing is sent anywhere.")
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
        .task(id: isEnabled) { availability = await intelligence?.availability() }
    }
}
