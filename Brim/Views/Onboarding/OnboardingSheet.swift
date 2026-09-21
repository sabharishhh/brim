import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// First run, and the only place Brim asks the person for anything.
///
/// Everything it needs is settled here, in one sitting, while they are
/// paying attention to setup rather than in the middle of looking at
/// something. After this the app is quiet: no permission dialog between a
/// person and a list they asked to see, and no fingerprint before anything
/// that can be undone.
///
/// It is setup, not a gate. Every step can be skipped and the app still
/// opens and still works, because a scan without Full Disk Access is not
/// wrong, it is smaller, and it says so. That is the permission ladder the
/// plan calls for, moved to the front rather than replaced by a wall.
struct OnboardingSheet: View {
    let service: any BrimServiceProtocol
    let onFinished: () -> Void

    private enum Step: Int, CaseIterable {
        case what, access, confirm
    }

    @State private var step: Step = .what
    @StateObject private var access = FullDiskAccessModel()
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(28)
        .frame(width: 560, height: 470)
        .onAppear { access.startObserving() }
        .onDisappear { access.stopObserving() }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .what: whatBrimDoes
        case .access: fullDiskAccess
        case .confirm: confirmOwnership
        }
    }

    private var whatBrimDoes: some View {
        VStack(alignment: .leading, spacing: 16) {
            title(
                "Welcome to Brim",
                "Brim tracks down what software leaves behind on this Mac, and shows you the "
                + "place is empty once you clear it out."
            )

            VStack(alignment: .leading, spacing: 12) {
                point(
                    "magnifyingglass",
                    "It looks in the places an uninstall misses.",
                    "Login items macOS still runs, launchd jobs pointing at programs that have "
                    + "gone, settings and caches nothing claims any more."
                )
                point(
                    "checkmark.seal",
                    "It checks its own work.",
                    "After a removal Brim goes back to every place it touched and tells you "
                    + "what it found there. It does not take its own word for it."
                )
                point(
                    "arrow.uturn.backward",
                    "Almost everything is undoable.",
                    "Things go to the Trash, where you can fish them back out. The rare step "
                    + "that cannot be undone is called out before it runs."
                )
            }
        }
    }

    private var fullDiskAccess: some View {
        VStack(alignment: .leading, spacing: 16) {
            title(
                "Let Brim read the Mac",
                "One setting, and it is the only one Brim asks for. macOS keeps the interesting "
                + "parts behind it: the list of login items, application containers, and the "
                + "records that say who installed what."
            )

            if access.isGranted {
                status(
                    "checkmark.circle.fill", .green,
                    "Brim can read everything it needs.",
                    "Nothing more to do here."
                )
            } else {
                status(
                    "lock.fill", .orange,
                    "Full Disk Access is off.",
                    "Brim still runs without it and still finds things. It just cannot see "
                    + "inside containers or read the login item list, and it will say so "
                    + "wherever that changes an answer, rather than showing you a zero it "
                    + "never earned."
                )

                Button {
                    access.requestAccess()
                } label: {
                    Label("Open System Settings", systemImage: "arrow.up.forward.app")
                }
                .controlSize(.large)

                if access.hasRequested {
                    Text("Find Brim in the list and switch it on. macOS will ask to quit Brim "
                         + "so the change takes effect. Open it again afterwards and setup "
                         + "carries on from here.")
                        .font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var confirmOwnership: some View {
        VStack(alignment: .leading, spacing: 16) {
            title(
                "One check, and then quiet",
                "Brim would like to confirm once that this Mac is yours. Doing it now is what "
                + "lets it stop asking later."
            )

            VStack(alignment: .leading, spacing: 12) {
                point(
                    "hand.raised",
                    "If you can undo it, Brim does not ask.",
                    "Anything bound for the Trash just goes. You looked at the list, and it is "
                    + "all still there if you change your mind."
                )
                point(
                    "exclamationmark.triangle",
                    "One prompt for the whole job, not one per file.",
                    "Brim asks again only when something is about to go for good, once for the "
                    + "entire plan, and then not again for five minutes."
                )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Chrome

    private func title(_ heading: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.largeTitle).fontWeight(.bold)
            Text(detail)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func point(_ symbol: String, _ heading: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3).foregroundColor(.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).fontWeight(.medium)
                Text(detail)
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func status(
        _ symbol: String, _ tint: Color, _ heading: String, _ detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundColor(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).fontWeight(.medium)
                Text(detail)
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            ForEach(Step.allCases, id: \.self) { each in
                Circle()
                    .fill(each == step ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }

            Spacer()

            if isWorking { ProgressView().controlSize(.small) }

            switch step {
            case .what:
                Button("Continue") { step = .access }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            case .access:
                // Skipping is a real choice, so it is the plain button
                // until the setting is on and continuing is the obvious
                // next move.
                if access.isGranted {
                    Button("Continue") { step = .confirm }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip for now") { step = .confirm }
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            case .confirm:
                Button("Not now") { onFinished() }
                    .disabled(isWorking)
                Button("Confirm and start") { Task { await enroll() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWorking)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 16)
    }

    private func enroll() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.enroll()
            onFinished()
        } catch {
            // Declining setup is not a failure worth blocking on, since
            // nothing depends on it. Say so plainly and let them carry on.
            errorMessage = error.localizedDescription
        }
    }
}
