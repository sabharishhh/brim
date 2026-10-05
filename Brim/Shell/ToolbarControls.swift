import BrimUI
import SwiftUI

/// Apps and Updates, one capsule with the chosen half lit. The light slides
/// across rather than jumping, and Updates carries its count once a check
/// has one. The system's segmented control drew a grey pill on grey glass
/// that read as two disabled buttons. VoiceOver is given that control,
/// which says what this is better than two buttons would.
struct LensSwitch: View {
    @Binding var lens: AppsLens
    @ObservedObject var updates: UpdatesModel
    @Namespace private var light
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppsLens.allCases, id: \.self) { item in
                Button {
                    lens = item
                } label: {
                    segment(item)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .animation(reduceMotion ? Motion.reduced : .spring(duration: 0.32, bounce: 0.12), value: lens)
        .accessibilityRepresentation {
            Picker("View", selection: $lens) {
                ForEach(AppsLens.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func segment(_ item: AppsLens) -> some View {
        let isOn = lens == item
        return HStack(spacing: 6) {
            Text(item.rawValue)
            if item == .updates, let count = updates.count, count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color.accentColor, in: .capsule)
            }
        }
        .font(.body.weight(.medium))
        .foregroundStyle(isOn ? Palette.ink : Palette.inkSecondary)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background {
            if isOn {
                Capsule()
                    .fill(.white.opacity(0.16))
                    .matchedGeometryEffect(id: "light", in: light)
            }
        }
        .contentShape(.capsule)
    }
}

/// The toolbar's one refresh, which is the page's own: Take a Reading on
/// Energy, Scan Again on Developer, Check Again elsewhere. While the page
/// is working it turns into a spinner, which replaced a spinner beside every
/// page title and Energy's own Take a Reading button, two controls that
/// did the same thing. A Developer scan can be stopped from it.
struct CheckAgainButton: View {
    @ObservedObject var activity: ScanActivity
    let destination: Destination
    let presses: Int
    let check: () -> Void
    let stop: () -> Void
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isBusy: Bool {
        activity.busy.contains(destination)
    }

    private var title: String {
        switch destination {
        case .energy: isBusy ? "Reading" : "Take a Reading"
        case .developer: isBusy ? "Stop Scanning" : "Scan Again"
        default: isBusy ? "Checking" : "Check Again"
        }
    }

    var body: some View {
        Button {
            if isBusy, destination == .developer {
                stop()
            } else {
                check()
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                if isBusy, destination == .developer {
                    Image(systemName: "stop.fill")
                } else if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        // Turns once per press, so the click is answered
                        // even before the check has anything to show.
                        .symbolEffect(.rotate.clockwise, options: .nonRepeating, value: presses)
                        .symbolEffectsRemoved(reduceMotion)
                }
            }
            .contentTransition(.opacity)
        }
        .disabled(isBusy && destination != .developer)
        .help("\(title) (⌘R)")
    }
}
