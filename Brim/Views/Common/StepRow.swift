import BrimCore
import BrimUI
import SwiftUI

/// One step: Finder's icon, the item's name and folder, its size.
struct StepRow: View {
    let step: Step

    var body: some View {
        if step.kind.targetIsPath {
            pathRow
        } else {
            // A command rather than a file: what runs, as the tool will run it.
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 22, height: 22)
                Text(step.evidence)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(step.evidence)
        }
    }

    private var pathRow: some View {
        let url = URL(fileURLWithPath: step.target)
        return HStack(spacing: 10) {
            BrimIcon(source: .finder(url), size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.ink)
                Text(Self.abbreviated(url.deletingLastPathComponent().path))
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            Text(ByteText.short(step.expectedBytes))
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("\(url.lastPathComponent), \(ByteText.short(step.expectedBytes))")
        .accessibilityValue(step.target)
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
