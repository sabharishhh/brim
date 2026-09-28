import BrimCore
import BrimPrivileged
import BrimUI
import SwiftUI

extension OnboardingSheet {
    /// Asked here, once, while the person is paying attention to setup,
    /// rather than in the middle of a removal. Most leftovers need nothing:
    /// on the Mac this was measured on, 164 of 184 were in folders the
    /// person owns. The rest sit where only an administrator can write, and
    /// the first scan, running behind this sheet, says how many here.
    var helperStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            title("System folders", "A few leftovers sit where only macOS can write")
            evidence
            if helperState == .ready {
                status(
                    "checkmark.circle.fill", .accentColor, "Helper on", "Moves those aside, where they can be put back"
                )
            } else {
                status(
                    "lock.shield", Palette.inkSecondary,
                    helperState == .waitingForApproval ? "Waiting in Login Items" : "Helper off",
                    "Runs only while Brim removes something"
                )
                HStack(spacing: 8) {
                    Button {
                        HelperRoute.turnOn()
                        helperState = HelperRoute.currentState()
                    } label: {
                        Label("Turn On Helper", systemImage: "lock.shield")
                    }
                    .buttonStyle(.glass)
                    Button("Check Again") { helperState = HelperRoute.currentState() }
                        .buttonStyle(.borderless)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
        .onAppear { helperState = HelperRoute.currentState() }
    }

    /// What the helper would do on this Mac, from the scan behind the sheet.
    @ViewBuilder
    private var evidence: some View {
        let count = leftovers.all.count { $0.capability == .needsHelper }
        HStack(spacing: 8) {
            if leftovers.checkedAt == nil {
                ProgressView().controlSize(.small)
                Text("Checking this Mac")
            } else {
                Image(systemName: count == 0 ? "checkmark" : "folder.badge.gearshape")
                Text(count == 0 ? "None on this Mac today" : count == 1
                    ? "1 leftover here needs it" : "\(count) leftovers here need it")
            }
        }
        .font(.brimFacts)
        .foregroundStyle(Palette.inkSecondary)
        .animation(Motion.standard, value: leftovers.checkedAt == nil)
    }
}
