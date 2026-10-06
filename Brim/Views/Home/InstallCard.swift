import BrimCore
import BrimUI
import SwiftUI

/// Before and during an install: look inside an installer, or record what
/// installing something does. While a recording is open it says since when,
/// and how to finish it.
struct InstallCard: View {
    @ObservedObject var recording: InstallRecordingModel
    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(ShellState.self) private var shell
    @State private var isTargeted = false

    var body: some View {
        // The same shape as the cards beside it: a heading, a line that
        // says what this is, and its actions along the bottom.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: recording.isRecording ? "record.circle" : "shippingbox")
                    .foregroundStyle(recording.isRecording ? Palette.caution : Palette.inkSecondary)
                    .symbolEffect(.pulse, options: .repeating, isActive: recording.isRecording)
                    .accessibilityHidden(true)
                Text("Installing")
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text(phrase)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            actions
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

    private var title: String {
        switch recording.phase {
        case let .recording(since), let .finishing(since):
            "Recording since \(Self.time.format(since))"
        case .starting:
            "Starting to record"
        default:
            "Before you install something"
        }
    }

    private var phrase: String {
        switch recording.phase {
        case .recording: "Install and open the app, then finish here"
        case .finishing: "Looking at what changed"
        case .starting: "Noting what is on this Mac now"
        default: "Drop an installer here to look inside, or record what installing does"
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch recording.phase {
        case .recording:
            HStack(spacing: 8) {
                Button("Cancel") { Task { await recording.cancel() } }
                    .capsuleAction()
                Button("Finish") { Task { await recording.finish() } }
                    .capsuleAction(prominent: true)
            }
        case .starting, .finishing:
            ProgressView().controlSize(.small)
        default:
            HStack(spacing: 8) {
                Button("Look Inside…") { shell.chooseInstaller() }
                    .capsuleAction()
                Button("Record an Install") { Task { await recording.start(service: service) } }
                    .capsuleAction()
            }
        }
    }

    private static let time = Date.FormatStyle.dateTime.hour().minute()
}
