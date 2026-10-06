import BrimCore
import BrimUI
import Charts
import SwiftUI

/// The last day of charge and sleep, from power management's own log.
///
/// The question it answers is the one people bring to an energy page: the
/// battery is lower than I left it, so what happened? The charge is a line
/// on a fixed 0 to 100% scale, since the range means something, and the
/// stretches asleep are shaded behind it, so a slope while asleep reads as
/// what sleeping cost. One sentence beside the title says the same in words.
/// Everything here already happened; nothing is drawn past now.
struct EnergyHistoryCard: View {
    let history: PowerHistory
    let battery: BatteryReport?
    var now = Date()

    private var start: Date {
        now.addingTimeInterval(-24 * 3600)
    }

    private var points: [PowerHistory.ChargePoint] {
        var points = history.charge.filter { $0.time >= start && $0.time <= now }
        if let earlier = history.charge.last(where: { $0.time < start }) {
            let edge = PowerHistory.ChargePoint(time: start, percent: earlier.percent, onBattery: earlier.onBattery)
            points.insert(edge, at: 0)
        }
        if let battery {
            points.append(PowerHistory.ChargePoint(
                time: now, percent: battery.percent, onBattery: battery.charging == .onBattery
            ))
        }
        return points
    }

    private var asleep: [DateInterval] {
        history.sleeps.compactMap { sleep in
            let from = max(sleep.span.start, start)
            let until = min(sleep.span.end, now)
            return until > from ? DateInterval(start: from, end: until) : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 24 hours")
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(summary)
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
            chart
                .frame(height: 140)
            HStack(spacing: 16) {
                legend(swatch: Capsule().fill(Palette.snow).frame(width: 14, height: 2), "Charge")
                legend(
                    swatch: RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.mist.opacity(0.5))
                        .frame(width: 12, height: 10),
                    "Asleep"
                )
            }
            .font(.caption)
            .foregroundStyle(Palette.inkSecondary)
            .accessibilityHidden(true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .hoverLift()
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("Last 24 hours")
        .accessibilityValue(spokenSummary)
    }

    private var chart: some View {
        Chart {
            ForEach(Array(asleep.enumerated()), id: \.offset) { _, span in
                RectangleMark(
                    xStart: .value("Asleep from", span.start), xEnd: .value("Asleep until", span.end),
                    yStart: .value("Bottom", 0), yEnd: .value("Top", 100)
                )
                .foregroundStyle(Palette.mist.opacity(0.5))
            }
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.time), y: .value("Charge", point.percent))
                    .foregroundStyle(Palette.snow)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
            }
        }
        .chartXScale(domain: start ... now)
        .chartYScale(domain: 0 ... 100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Palette.well)
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text("\(percent)%")
                    }
                }
                .foregroundStyle(Palette.inkTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisValueLabel(format: .dateTime.hour())
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
    }

    private func legend(swatch: some View, _ title: String) -> some View {
        HStack(spacing: 6) {
            swatch
            Text(title)
        }
    }

    /// The most recent sleep of half an hour or more in the last day and a
    /// half, in a few words.
    private var summary: String {
        guard let sleep = history.lastSleep, sleep.span.end > now.addingTimeInterval(-36 * 3600) else {
            return "No long sleep recorded"
        }
        let length = Self.duration(sleep.duration)
        if let used = sleep.chargeUsed {
            return "Last asleep \(length), \(used)% used"
        }
        return "Last asleep \(length), on the adapter"
    }

    private var spokenSummary: String {
        var parts: [String] = []
        if let first = points.first, let last = points.last {
            parts.append("Charge from \(first.percent) percent to \(last.percent) percent")
        }
        parts.append(summary)
        return parts.joined(separator: ". ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
