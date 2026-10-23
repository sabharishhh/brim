import BrimCore
import BrimUI
import Charts
import SwiftUI

/// The last day of charge and sleep, from power management's log. Charge is
/// a line on a fixed 0 to 100% scale with sleep shaded behind it, so a slope
/// while asleep shows what sleeping cost. Time on the adapter is dashed, the
/// line breaks at a restart, and nothing is drawn past now.
struct EnergyHistoryCard: View {
    let history: PowerHistory
    let battery: BatteryReport?
    let now: Date

    /// Worked out once when the card is made, not on every draw.
    private let start: Date
    private let restarts: [Date]
    private let points: [PowerHistory.ChargePoint]
    private let runs: [Run]
    private let asleep: [DateInterval]

    init(history: PowerHistory, battery: BatteryReport?, now: Date = Date()) {
        self.history = history
        self.battery = battery
        self.now = now
        let start = now.addingTimeInterval(-24 * 3600)
        let restarts = history.restarts.filter { $0 > start && $0 <= now }
        let points = Self.points(history: history, battery: battery, from: start, to: now, restarts: restarts)
        self.start = start
        self.restarts = restarts
        self.points = points
        runs = Self.runs(points, restarts: restarts)
        asleep = history.sleeps.compactMap { sleep in
            let from = max(sleep.span.start, start)
            let until = min(sleep.span.end, now)
            return until > from ? DateInterval(start: from, end: until) : nil
        }
    }

    /// One stretch of the line: the same power source, no restart inside.
    private struct Run: Identifiable {
        let id: Int
        let onBattery: Bool
        var points: [PowerHistory.ChargePoint]
    }

    private static func points(
        history: PowerHistory, battery: BatteryReport?, from start: Date, to now: Date, restarts: [Date]
    ) -> [PowerHistory.ChargePoint] {
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

    /// Splits the line where the power source changes, joining the two
    /// pieces at the change, and leaves a gap at every restart.
    private static func runs(_ points: [PowerHistory.ChargePoint], restarts: [Date]) -> [Run] {
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
                .overlay {
                    if !hasLine {
                        Text(restarts.isEmpty ? "Charge is logged at sleep and wake"
                            : "No charge logged since the restart")
                            .font(.brimFacts)
                            .foregroundStyle(Palette.inkSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Palette.surface, in: .capsule)
                    }
                }
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
                    // Beside the line at the top of the plot; below it, the label hid an hour
                    // label.
                    .annotation(
                        position: .trailing, alignment: .top, spacing: 4,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
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

    /// Whether any stretch has two points to draw between. Charge is logged only
    /// at sleep and wake, so a Mac awake since its restart has just one point.
    private var hasLine: Bool {
        runs.contains { $0.points.count > 1 }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            // Only what is drawn: a stretch of one point is no line.
            if runs.contains(where: { $0.onBattery && $0.points.count > 1 }) {
                key(Capsule().fill(Palette.snow).frame(width: 14, height: 2), "On battery")
            }
            if runs.contains(where: { !$0.onBattery && $0.points.count > 1 }) {
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

    /// What the latest long sleep in the last day cost the battery, said with
    /// when it was. A sleep on the adapter is not described.
    private var summary: String? {
        guard let sleep = history.lastSleep, sleep.span.end > start, let used = sleep.chargeUsed else { return nil }
        let from = Self.time.string(from: sleep.span.start), until = Self.time.string(from: sleep.span.end)
        return "Asleep \(from) to \(until), \(used)% used"
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
