import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

// swiftformat:disable wrapMultilineStatementBraces
/// The battery at a glance: charge, whether it is charging, its health, and
/// the last long sleep with what it cost. Past facts only, never a time
/// left on the charge (`BatteryLifeProjectionTests`). Read without
/// sampling, which is the Energy page's to do.
struct HomeEnergyCard: View {
    @ObservedObject var energy: EnergyModel
    let action: () -> Void

    var body: some View {
        if !energy.hasReadBattery {
            StatCard(title: "Energy", symbol: "bolt", figure: "…", status: .checking, phrase: "Checking",
                     fillsRow: true, action: action)
        } else if let battery = energy.battery {
            StatCard(
                title: "Energy", symbol: "bolt", figure: "\(battery.percent)%",
                status: battery.health?.needsService == true ? .attention : .neutral,
                phrase: Self.state(battery.charging), fillsRow: true
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    MeterBar(segments: [
                        MeterSegment(label: "Charge", value: Int64(battery.percent), color: Palette.snow),
                        MeterSegment(label: "Used", value: Int64(100 - battery.percent), color: Palette.well)
                    ], showsLegend: false)
                    lines([health(battery.health), sleep])
                }
            } action: { action() }
        } else {
            // A Mac with no battery: what kept it awake instead.
            StatCard(title: "Energy", symbol: "bolt", figure: "Plugged in", status: .neutral,
                     phrase: "No battery", fillsRow: true) {
                lines([sleep, awake])
            } action: { action() }
        }
    }

    private func lines(_ texts: [String?]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(texts.compactMap(\.self), id: \.self) { text in
                Text(text)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
            }
        }
    }

    static func state(_ charging: BatteryReport.Charging) -> String {
        switch charging {
        case .onBattery: "On battery"
        case .charging: "Charging"
        case .pluggedInNotCharging: "Plugged in, not charging"
        case .charged: "Charged"
        }
    }

    private func health(_ health: BatteryReport.Health?) -> String? {
        guard let health else { return nil }
        var parts = ["Health \(health.condition)"]
        if let capacity = health.maximumCapacity {
            parts.append("\(capacity)% capacity")
        }
        if let cycles = health.cycles {
            parts.append(cycles == 1 ? "1 cycle" : "\(cycles) cycles")
        }
        return parts.joined(separator: " · ")
    }

    /// How much charge the last sleep of half an hour or more used, said
    /// with its day so it is never read as the night just gone. A sleep on
    /// the adapter used nothing measurable, and "on the adapter" beside it
    /// read as a second, confusing account of the power state, so the card
    /// says nothing about it.
    private var sleep: String? {
        guard let sleep = energy.history?.lastSleep, let used = sleep.chargeUsed else { return nil }
        return "Asleep \(Self.moment(sleep.span.start)) to \(Self.moment(sleep.span.end)), \(used)% used"
    }

    private var awake: String? {
        guard let first = energy.awakeRequests.first else { return nil }
        return "Kept awake most by \(first.name), \(EnergyHistoryCard.duration(first.seconds))"
    }

    /// A time today, "yesterday" and a time, or a weekday and a time.
    static func moment(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = timeStyle.format(date)
        if calendar.isDate(date, inSameDayAs: now) {
            return time
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(time)"
        }
        return "\(dayStyle.format(date)) \(time)"
    }

    private static let timeStyle = Date.FormatStyle.dateTime.hour().minute()
    private static let dayStyle = Date.FormatStyle.dateTime.weekday(.abbreviated)
}

/// What Brim removed, and whether it is still gone.
struct HomeJournalCard: View {
    @ObservedObject var history: RemovalHistoryModel
    let action: () -> Void

    var body: some View {
        let records = history.records.filter { $0.plan.intent.type == .uninstall }
        let cameBack = history.cameBackCount
        StatCard(
            title: "Journal", symbol: "book.closed",
            figure: history.isLoading && records.isEmpty ? "…"
                : (records.isEmpty ? "No removals" : (records.count == 1 ? "1 removal" : "\(records.count) removals")),
            status: history.isLoading && records.isEmpty ? .checking
                : (cameBack > 0 ? .attention : (history.rechecks.isEmpty ? .neutral : .clear)),
            phrase: phrase(records: records.count, cameBack: cameBack), fillsRow: true
        ) {
            if let last = records.first {
                Text("Last: \(last.name), \(last.occurred)")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
            }
        } action: { action() }
    }

    private func phrase(records: Int, cameBack: Int) -> String {
        if records == 0 {
            // What the card will say, once there is something to say it about.
            return "Each removal is checked again later"
        }
        if cameBack > 0 {
            return cameBack == 1 ? "1 came back" : "\(cameBack) came back"
        }
        return history.rechecks.isEmpty ? "Not checked again yet" : "All still gone"
    }
}
