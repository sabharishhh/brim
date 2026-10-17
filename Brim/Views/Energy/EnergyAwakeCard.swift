import BrimCore
import BrimUI
import SwiftUI

/// Which apps asked the Mac to stay awake over the days power management's
/// log covers, and for how long. "Asked", because a request only stops
/// sleep while nobody is using the Mac. Bars share one scale, and an app
/// holding a request right now is marked Now.
struct EnergyAwakeCard: View {
    let requests: [EnergyModel.AwakeRequest]
    /// Applications holding a request at the moment of the reading.
    let holding: [PowerAssertions.Held]
    let since: Date?
    var now = Date()

    private struct Row: Identifiable {
        let name: String
        let bundlePath: String?
        let seconds: TimeInterval?
        let isNow: Bool
        var id: String {
            bundlePath ?? name
        }
    }

    private var rows: [Row] {
        let current = Set(holding.compactMap(\.bundlePath))
        var rows = requests.prefix(6).map {
            Row(name: $0.name, bundlePath: $0.bundlePath, seconds: $0.seconds, isNow: current.contains($0.bundlePath))
        }
        let listed = Set(rows.compactMap(\.bundlePath))
        var named = Set(rows.map(\.name))
        for held in holding where !(held.bundlePath.map(listed.contains) ?? false) && !named.contains(held.owner) {
            rows.append(Row(name: held.owner, bundlePath: held.bundlePath, seconds: nil, isNow: true))
            named.insert(held.owner)
        }
        return rows
    }

    private var covered: TimeInterval {
        max(3600, now.timeIntervalSince(since ?? now.addingTimeInterval(-7 * 24 * 3600)))
    }

    /// The days the log covers, which the hours add up over and the bars are
    /// measured against.
    private var period: String {
        let days = Int((covered / 86400).rounded(.up))
        return days <= 1 ? "Last day" : "Last \(days) days"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Asked the Mac to stay awake")
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(period)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            ForEach(rows) { row in
                rowView(row)
            }
        }
        .padding(8)
        .card()
        .hoverLift()
    }

    private func rowView(_ row: Row) -> some View {
        let figure = row.seconds.map { EnergyHistoryCard.duration($0) } ?? "Now"
        return HStack(spacing: 12) {
            BrimIcon(
                source: row.bundlePath.map { .bundle(URL(fileURLWithPath: $0)) } ?? .monogram(Monogram(name: row.name)),
                size: Metrics.compactRowIcon
            )
            HStack(spacing: 6) {
                Text(row.name)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if row.isNow, row.seconds != nil {
                    Text("Now")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Palette.selected, in: .capsule)
                }
            }
            .frame(width: 190, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.well)
                    if let seconds = row.seconds {
                        Capsule()
                            .fill(Palette.snow)
                            .frame(width: max(3, proxy.size.width * min(1, seconds / covered)))
                    }
                }
            }
            .frame(height: 5)
            Text(figure)
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(row.name)
        .accessibilityValue(
            row.seconds.map { "Asked for \(EnergyHistoryCard.duration($0)) in the \(period.lowercased())"
                + (row.isNow ? ", and asking now" : "")
            } ?? "Asking now"
        )
    }
}
