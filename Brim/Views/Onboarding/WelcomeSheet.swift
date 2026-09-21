import SwiftUI
import BrimProtocol

/// First run, and the only time Brim asks for a fingerprint without something
/// being about to be destroyed.
///
/// It is setup rather than a gate: skipping it withholds nothing. What it
/// buys is the right to be quiet afterwards — having confirmed once who owns
/// this Mac, Brim can stop asking before every reversible change and keep
/// the prompt for the one case that earns it.
struct WelcomeSheet: View {
    let service: any BrimServiceProtocol
    let onFinished: () -> Void

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Brim")
                    .font(.largeTitle).fontWeight(.bold)
                Text("Brim tracks down what software leaves behind on this Mac, and shows you the "
                     + "place is empty once you clear it out.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                promise(
                    "hand.raised",
                    "Brim asks you once, right now.",
                    "From here on Brim stays quiet. The one time it asks again is right before "
                    + "something goes for good."
                )
                promise(
                    "arrow.uturn.backward",
                    "If you can undo it, Brim does not ask.",
                    "Anything bound for the Trash just goes. You looked at the list, and you can "
                    + "always fish it back out."
                )
                promise(
                    "checkmark.seal",
                    "Brim checks its own work.",
                    "Brim goes back and looks at every place it touched, then tells you what it "
                    + "saw. It does not take its own word for it."
                )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Not now") { onFinished() }
                    .disabled(isWorking)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Confirm and continue") { Task { await enroll() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWorking)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520, height: 430)
    }

    private func promise(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func enroll() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.enroll()
            onFinished()
        } catch {
            // Declining setup is not a failure worth blocking on — nothing
            // depends on it — so say so plainly and let them carry on.
            errorMessage = error.localizedDescription
        }
    }
}
