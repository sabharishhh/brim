import BrimUI
import SwiftUI

/// Apps and Updates as one capsule with the chosen half lit; Updates shows
/// its count once a check has one. VoiceOver is given a segmented control,
/// which describes it better than two buttons.
struct LensSwitch: View {
    @Binding var lens: AppsLens
    @ObservedObject var updates: UpdatesModel
    @Namespace private var light
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Room inside the outer capsule, so the selection never touches
        // its edge, and between the two segments.
        HStack(spacing: 4) {
            ForEach(AppsLens.allCases, id: \.self) { item in
                Button {
                    lens = item
                } label: {
                    segment(item)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
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
        return HStack(spacing: 8) {
            Text(item.rawValue)
            if item == .updates, let count = updates.count, count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isOn ? Palette.snow : Palette.onSnow)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(isOn ? Palette.onSnow : Palette.snow, in: .capsule)
            }
        }
        .font(.body.weight(.medium))
        .foregroundStyle(isOn ? Palette.onSnow : Palette.inkSecondary)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background {
            if isOn {
                // The selected segment is off-white with near-black text,
                // as a selected sidebar row is.
                Capsule()
                    .fill(Palette.snow)
                    .matchedGeometryEffect(id: "light", in: light)
            }
        }
        .contentShape(.capsule)
    }
}

/// The toolbar's sign that a page is checking: a spinner while it works,
/// nothing otherwise, since pages keep themselves current (`KeepsCurrent`).
/// Updates keeps Check Again because it asks the network, and a Developer
/// scan can be stopped. Check Again stays in the menu and command bar.
struct CheckAgainButton: View {
    @ObservedObject var activity: ScanActivity
    let destination: Destination
    let lens: AppsLens
    let presses: Int
    let check: () -> Void
    let stop: () -> Void
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isBusy: Bool {
        activity.busy.contains(destination)
    }

    var body: some View {
        Group {
            if destination == .apps, lens == .updates {
                checkUpdates
            } else if destination == .developer, isBusy {
                Button(action: stop) {
                    Label("Stop Scanning", systemImage: "stop.fill")
                }
                .help("Stop Scanning")
            } else if isBusy {
                // A toolbar button so it gets the same round glass as the others; a bare
                // spinner got a tall, narrow pill. Inert, and read as text.
                Button {} label: {
                    Label {
                        Text("Checking")
                    } icon: {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .labelStyle(.iconOnly)
                .allowsHitTesting(false)
                .help("Checking")
                .accessibilityRemoveTraits(.isButton)
                .accessibilityAddTraits(.isStaticText)
                .transition(.opacity)
            }
        }
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: isBusy)
    }

    private var checkUpdates: some View {
        Button(action: check) {
            Label {
                Text(isBusy ? "Checking" : "Check Again")
            } icon: {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()
                        .frame(width: 16, height: 16)
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
        .disabled(isBusy)
        .help(isBusy ? "Checking" : "Check Again (⌘R)")
    }
}
