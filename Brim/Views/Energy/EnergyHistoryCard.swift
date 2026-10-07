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
/// what sleeping cost. Everything here already happened; nothing is drawn
/// past now.
///
/// The first version drew one flat white line across the whole day on a
/// Mac that sat at its charge limit and restarted in the morning: true, and
/// it said nothing. Time on the adapter is now dashed, so a flat line at
/// the limit explains itself, and the line breaks at a restart, which is
/// marked, because the hours before one may have been spent switched off.
/// The sentence beside the title used to read "Last asleep 1 h 3 min" for
/// a nap the afternoon before, which sounded like the night just gone; it
/// now says when.
struct EnergyHistoryCard: View {
    let history: PowerHistory
    let battery: BatteryReport?
    var now = Date()

    private var start: Date {
        now.addingTimeInterval(-24 * 3600)
    }

    /// One stretch of the line: the same power source, no restart inside.
    private struct Run: Identifiable {
        let id: Int
        let onBattery: Bool
        var points: [PowerHistory.ChargePoint]
    }

    private var points: [PowerHistory.ChargePoint] {
        var points = history.charge.filter { $0.time >= start && $0.time <= now }
        // Carried in from before the window, unless a restart lies between.
        let firstInside = points.first?.time ?? now
        let carried = restarts.contains { $0 < firstInside } ? nil : history.charge.last { $0.time < start }
        if let earlier = carried {
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

    private var restarts: [Date] {
        history.restarts.filter { $0 > start && $0 <= now }
    }

    /// Splits the line where the power source changes, joining the two
    /// pieces at the change, and leaves a gap at every restart.
    private var runs: [Run] {
        var runs: [Run] = []
        var previous: PowerHistory.ChargePoint?
        for point in points {
            let restarted = previous.map { last in restarts.contains { $0 > last.time && $0 <= point.time } } ?? false
            if var current = runs.last, !restarted, current.onBattery == point.onBattery {
                current.points.append(point)
                runs[runs.count - 1] = current
            } else {
                var run = Run(id: runs.count, onBattery: point.onBattery, points: [point])
                if let previous, !restarted {
                    run.points.insert(previous, at: 0)
                }
                runs.append(run)
            }
            previous = point
        }
        return runs
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
                Text(summary ?? "")
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
            chart
                .frame(height: 140)
            legend
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
            ForEach(restarts, id: \.self) { restart in
                RuleMark(x: .value("Restarted", restart))
                    .foregroundStyle(Palette.frost)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .bottom, alignment: .trailing, spacing: 2) {
                        Text("Restarted")
                            .font(.caption2)
                            .foregroundStyle(Palette.inkSecondary)
                    }
            }
            ForEach(runs) { run in
                ForEach(Array(run.points.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.time), y: .value("Charge", point.percent),
                        series: .value("Stretch", run.id)
                    )
                    .foregroundStyle(run.onBattery ? Palette.snow : Palette.frost)
                    .lineStyle(StrokeStyle(
                        lineWidth: 2, lineCap: .round, lineJoin: .round, dash: run.onBattery ? [] : [5, 4]
                    ))
                    .interpolationMethod(.linear)
                }
            }
            // Charge is recorded only when the Mac sleeps or wakes, so after
            // a restart with neither there is no line, only the charge now.
            if let battery {
                PointMark(x: .value("Now", now), y: .value("Charge", battery.percent))
                    .foregroundStyle(Palette.snow)
                    .symbolSize(30)
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

    private var legend: some View {
        HStack(spacing: 16) {
            if runs.contains(where: \.onBattery) {
                key(Capsule().fill(Palette.snow).frame(width: 14, height: 2), "On battery")
            }
            if runs.contains(where: { !$0.onBattery }) {
                key(
                    Line().stroke(Palette.frost, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .frame(width: 14, height: 2),
                    "On the adapter"
                )
            }
            if !asleep.isEmpty {
                key(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.mist.opacity(0.5))
                        .frame(width: 12, height: 10),
                    "Asleep"
                )
            }
        }
        .font(.caption)
        .foregroundStyle(Palette.inkSecondary)
        .accessibilityHidden(true)
    }

    private func key(_ swatch: some View, _ title: String) -> some View {
        HStack(spacing: 6) {
            swatch
            Text(title)
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    /// The most recent sleep of half an hour or more in the last day, by
    /// when it was, so it is never read as the night just gone.
    /// What the last long sleep in this time cost the battery. A sleep on
    /// the adapter cost nothing measurable, and the shaded band already
    /// shows it, so it is not described.
    private var summary: String? {
        guard let sleep = history.lastSleep, sleep.span.end > start, let used = sleep.chargeUsed else { return nil }
        let start = Self.time.string(from: sleep.span.start), end = Self.time.string(from: sleep.span.end)
        return "Asleep \(start) to \(end), \(used)% used"
    }

    private var spokenSummary: String {
        var parts: [String] = []
        if let first = points.first, let last = points.last {
            parts.append("Charge from \(first.percent) percent to \(last.percent) percent")
        }
        if !restarts.isEmpty {
            parts.append(restarts.count == 1 ? "Restarted once" : "Restarted \(restarts.count) times")
        }
        if let summary {
            parts.append(summary)
        }
        return parts.joined(separator: ". ")
    }

    /// Minutes under an hour, hours and minutes under ten hours, and whole
    /// hours past that, where minutes are only noise.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return "\(minutes) min"
        }
        if minutes >= 600 {
            return "\(Int((Double(minutes) / 60).rounded())) h"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

/// A horizontal line, for the dashed legend key.
private nonisolated struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
