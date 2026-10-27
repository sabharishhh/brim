import BrimUI
import SwiftUI

/// A download's progress ring that stops the download when clicked; under
/// the pointer it shows a cross. What arrived is kept for a day, so Update
/// resumes from there. A real button, reachable by keyboard and VoiceOver.
struct DownloadRing: View {
    let fraction: Double
    let stop: () -> Void

    var body: some View {
        Button(action: stop) {
            EmptyView()
        }
        .buttonStyle(RingStyle(fraction: fraction))
        .help("Stop Download")
        .accessibilityLabel("Stop Download")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent downloaded")
    }
}

private struct RingStyle: ButtonStyle {
    let fraction: Double

    func makeBody(configuration: Configuration) -> some View {
        RingBody(fraction: fraction, isPressed: configuration.isPressed)
    }
}

/// Hover is answered inside the button's own body, as in `ActionStyle`: an
/// overlay or tracking view on a button never sees the pointer.
private struct RingBody: View {
    let fraction: Double
    let isPressed: Bool
    @State private var isHovering = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isHovering {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.ink)
                    .transition(.opacity)
            } else {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .transition(.opacity)
            }
        }
        .frame(width: 22, height: 22)
        .contentShape(.circle)
        .actionPointer()
        .scaleEffect(isPressed && !reduceMotion ? 0.9 : 1)
        .onHover { isHovering = $0 }
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: isHovering)
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: isPressed)
    }
}
