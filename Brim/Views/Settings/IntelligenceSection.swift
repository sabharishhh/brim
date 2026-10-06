import BrimUI
import SwiftUI

/// Whether Brim asks the on-device model, and whether it can.
///
/// The switch is Brim's; the state beside it is the Mac's, in words, so a
/// person who sees no summaries knows whether to look here or in System
/// Settings. Nothing leaves the Mac either way.
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
