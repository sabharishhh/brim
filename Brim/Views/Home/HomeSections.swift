import BrimCore
import BrimUI
import SwiftUI
import TipKit
import UniformTypeIdentifiers

/// Where an app is dropped to open everything it put on this Mac. Glass
/// only while something is over it, which is when it is a control.
struct DropWell: View {
    let onDrop: ([URL]) -> Bool
    @State private var isTargeted = false
    @State private var showsChooser = false
    @State private var chooserError: String?
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.app")
                .font(.title2)
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.inkTertiary))
                .symbolEffect(.bounce, value: isTargeted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop an app to inspect it")
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text("Everything it installed, in one place")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            Button("Inspect an app") { showsChooser = true }
                .buttonStyle(InspectionButtonStyle(isTrackingSuspended: isTargeted))
                .accessibilityHint("Choose an application to inspect in Apps")
        }
        .padding(20)
        // A card like the others at rest, with no outline. It lights with
        // the accent only while something is over it.
        .background(
            isTargeted ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(Palette.surface),
            in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous)
        )
        .glassEffect(
            isTargeted ? .regular.tint(.accentColor.opacity(0.12)) : .identity,
            in: .rect(cornerRadius: Metrics.cardRadius)
        )
        .dropDestination(for: URL.self) { urls, _ in
            BrimTips.learned(DropAppTip())
            return onDrop(urls)
        } isTargeted: { isTargeted = $0 }
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: isTargeted)
        .symbolEffectsRemoved(reduceMotion)
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
