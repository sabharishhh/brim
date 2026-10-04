import BrimCore
import BrimUI
import SwiftUI
import TipKit
import UniformTypeIdentifiers

/// Where an app is dropped to open everything it put on this Mac.
///
/// One response to a drag, not three: an inset edge in the accent appears
/// while something is over it. It used to tint, turn to glass and bounce
/// its symbol at once. A drop that is not an app is refused the native way
/// and the well says why, in place, instead of doing nothing.
struct DropWell: View {
    let onDrop: ([URL]) -> Bool
    @State private var isTargeted = false
    /// Why the last drop was refused, until the next drag arrives.
    @State private var refusal: String?
    @State private var showsChooser = false
    @State private var chooserError: String?
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.app")
                .font(.title2)
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.inkTertiary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop an app to inspect it")
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                if let refusal {
                    Label(refusal, systemImage: "exclamationmark.triangle.fill")
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary, Palette.caution)
                } else {
                    Text("Everything it installed, in one place")
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            Spacer()
            Button("Inspect an app") { showsChooser = true }
                .buttonStyle(InspectionButtonStyle(isTrackingSuspended: isTargeted))
                .accessibilityHint("Choose an application to inspect in Apps")
        }
        .padding(20)
        // A card like the others at rest, with no outline. While something
        // is over it, a defined inset edge says this is where it goes.
        .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(.tint, lineWidth: 1.5)
                .padding(3)
                .opacity(isTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self) { urls, _ in
            BrimTips.learned(DropAppTip())
            let accepted = onDrop(urls)
            refusal = accepted ? nil : "Only an app can be inspected"
            return accepted
        } isTargeted: { targeted in
            isTargeted = targeted
            if targeted {
                refusal = nil
            }
        }
        // In quickly, out in 120 ms, and only a fade either way.
        .animation(Motion.resolved(isTargeted ? Motion.acknowledge : Motion.leave, reduceMotion: reduceMotion),
                   value: isTargeted)
        .fileImporter(isPresented: $showsChooser, allowedContentTypes: [.applicationBundle]) { result in
            switch result {
            case let .success(url):
                _ = onDrop([url])
            case let .failure(error):
                chooserError = error.localizedDescription
            }
        }
        .fileDialogDefaultDirectory(URL(filePath: "/Applications", directoryHint: .isDirectory))
        .fileDialogConfirmationLabel("Inspect")
        .alert("Couldn't open the application chooser", isPresented: Binding(
            get: { chooserError != nil },
            set: {
                if !$0 {
                    chooserError = nil
                }
            }
        )) {
            Button("OK") { chooserError = nil }
        } message: {
            Text(chooserError ?? "")
        }
        .popoverTip(DropAppTip(), arrowEdge: .top)
    }
}
