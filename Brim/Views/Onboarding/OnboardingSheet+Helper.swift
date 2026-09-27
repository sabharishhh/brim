import BrimPrivileged
import BrimUI
import SwiftUI

extension OnboardingSheet {
    /// Asked here, once, while the person is paying attention to setup,
    /// rather than in the middle of a removal. Most leftovers need nothing:
    /// on the Mac this was measured on, 164 of 184 were in folders the
    /// person owns. The rest sit where only an administrator can write.
    var helperStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            title(
                "Leftovers in system folders",
                "Most of what Brim removes is in your own folders and needs nothing. A few "
                    + "leftovers sit where only macOS can make changes, such as broken commands "
                    + "in /usr/local/bin. Brim's helper moves those aside for you, where they can "
                    + "still be put back."
            )

            if helperState == .ready {
                status(
                    "checkmark.circle.fill", .green,
                    "Brim's helper is on.",
                    "Nothing more to do here."
                )
            } else {
                status(
                    "lock.shield", .secondary,
                    helperState == .waitingForApproval
                        ? "Waiting for you in Login Items."
                        : "Brim's helper is off.",
                    "macOS asks you to allow it once, in Login Items. It runs only while Brim "
                        + "is removing something, and it will only move leftovers it can prove are "
                        + "unused."
                )

                HStack {
                    Button {
                        HelperRoute.turnOn()
                        helperState = HelperRoute.currentState()
                    } label: {
                        Label("Turn On Brim's Helper", systemImage: "lock.shield")
                    }
                    .controlSize(.large)
                    Button("Check Again") { helperState = HelperRoute.currentState() }
                }
            }
        }
        .onAppear { helperState = HelperRoute.currentState() }
    }
}
