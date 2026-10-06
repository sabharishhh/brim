import BrimCore
import BrimUI
import SwiftUI

/// What grew or shrank since the last visit, by subtraction.
///
/// Both figures were measured: this visit's, and the one recorded at the
/// end of the visit before. Nothing in between was watched, so the card
/// says what is different, never when or why. Free space leads, because it
/// is the number people come to Space about; then the rows and apps that
/// moved by 100 MB or more, largest first.
struct SpaceChangesCard: View {
    let previous: SpaceSnapshot?
    let current: SpaceSnapshot

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Since you last looked")
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
                Spacer()
                if let previous {
                    Text(Self.day.string(from: previous.date))
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            if let previous {
                let changes = [SpaceChange(title: "Free space", bytes: current.free - previous.free)]
                    + SpaceHistory.changes(from: previous, to: current)
                let scale = max(1, changes.map { abs($0.bytes) }.max() ?? 1)
                ForEach(changes) { change in
                    row(change, scale: scale)
                }
            } else {
                Text("Changes show from your next visit")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .padding(8)
        .card()
        .hoverLift()
    }

    private func row(_ change: SpaceChange, scale: Int64) -> some View {
        let figure = change.bytes == 0 ? "No change"
            : (change.bytes > 0 ? "+" : "\u{2212}") + ByteText.short(abs(change.bytes))
        return HStack(spacing: 12) {
            Text(change.title)
                .font(.brimRowTitle)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.well)
                    if change.bytes != 0 {
                        Capsule()
                            .fill(Palette.snow)
                            .frame(width: max(3, proxy.size.width * Double(abs(change.bytes)) / Double(scale)))
                    }
                }
            }
            .frame(height: 6)
            Text(figure)
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(change.title)
        .accessibilityValue(change.bytes == 0 ? "No change"
            : "\(change.bytes > 0 ? "Up" : "Down") \(ByteText.short(abs(change.bytes)))")
    }
}
