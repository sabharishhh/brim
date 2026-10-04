import BrimCore
import BrimUI
import SwiftUI
import TipKit

/// Where an app is dropped to open everything it put on this Mac. Glass
/// only while something is over it, which is when it is a control.
struct DropWell: View {
    let onDrop: ([URL]) -> Bool
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.app")
                .font(.title2)
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.inkTertiary))
                .symbolEffect(.bounce, value: isTargeted)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop an app to inspect it")
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text("Everything it installed, in one place")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
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
        .animation(Motion.quick, value: isTargeted)
        .accessibilityElement(children: .combine)
        .popoverTip(DropAppTip(), arrowEdge: .top)
    }
}
