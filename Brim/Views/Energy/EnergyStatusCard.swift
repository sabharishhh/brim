import BrimCore
import BrimUI
import SwiftUI

/// The battery, the whole Mac's draw and the temperature, in one card.
///
/// Two large cards used to say "Temperature: Normal, No slowdown" and
/// "Power: Plugged in" and nothing else, which is a lot of window for
/// two facts. The battery's own condition, capacity and cycles sat in
/// System Settings and System Information, and the whole Mac's draw was
/// nowhere at all. Temperature is still Apple's thermal state, not
/// degrees: there is no public interface for a temperature, and the
/// question a person has is whether the Mac is slowing down.
struct EnergyStatusCard: View {
    let battery: BatteryReport?
    let condition: SystemCondition

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                if let battery {
                    batteryColumn(battery)
                    if let watts = battery.drawWatts {
                        statusColumn(
                            caption: "Drawing now", symbol: "bolt",
                            figure: String(format: watts < 10 ? "%.1f W" : "%.0f W", watts),
                            phrase: drawSource(battery), status: .neutral
                        )
                    }
                } else if condition.power != nil || condition.lowPowerMode {
                    statusColumn(
                        caption: "Power", symbol: "powerplug", figure: "Plugged in",
                        phrase: condition.lowPowerMode ? "Low Power Mode on" : nil, status: .neutral
                    )
                }
                statusColumn(
                    caption: "Temperature", symbol: condition.thermal.symbolName,
                    figure: condition.thermal.title,
                    phrase: condition.thermal.isNoteworthy ? "Slowing down to cool" : "No slowdown",
                    status: condition.thermal.isNoteworthy ? .attention : .clear,
                    tint: EnergyTone.thermal(condition.thermal)
                )
            }
            if let health = battery?.health {
                healthLine(health)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .hoverLift()
    }

    private func batteryColumn(_ battery: BatteryReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Battery")
            } icon: {
                Image(systemName: batterySymbol(battery))
                    .foregroundStyle(EnergyTone.battery(
                        percent: battery.percent, onBattery: battery.charging == .onBattery,
                        lowPowerMode: condition.lowPowerMode
                    ))
            }
            .font(.brimGroupTitle)
            .foregroundStyle(Palette.ink)
            Text("\(battery.percent)%")
                .font(.brimFigure)
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText())
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.well)
                    Capsule().fill(Palette.snow)
                        .frame(width: max(4, proxy.size.width * Double(battery.percent) / 100))
                }
            }
            .frame(height: 6)
            .frame(maxWidth: 160)
            Text(chargingPhrase(battery))
                .font(.brimFacts)
                .foregroundStyle(Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("Battery, \(battery.percent) percent, \(chargingPhrase(battery))")
    }

    private func statusColumn(
        caption: String, symbol: String, figure: String, phrase: String?, status: CardStatus, tint: Color? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(caption)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(tint ?? Palette.ink)
            }
            .font(.brimGroupTitle)
            .foregroundStyle(Palette.ink)
            Text(figure)
                .font(.brimFigure)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            if let phrase {
                HStack(spacing: 6) {
                    if status == .attention {
                        StatusDot(status: status)
                    }
                    Text(phrase)
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel([caption, figure, phrase].compactMap(\.self).joined(separator: ", "))
    }

    /// Condition, capacity and cycles, worded as System Settings words them.
    private func healthLine(_ health: BatteryReport.Health) -> some View {
        var parts = ["Battery health \(health.condition)"]
        if let capacity = health.maximumCapacity {
            parts.append("\(capacity)% of original capacity")
        }
        if let cycles = health.cycles {
            parts.append(cycles == 1 ? "1 cycle" : "\(cycles) cycles")
        }
        return VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(Palette.well)
            HStack(spacing: 6) {
                if health.needsService {
                    StatusDot(status: .attention)
                }
                Text(parts.joined(separator: " · "))
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(parts.joined(separator: ", "))
    }

    private func chargingPhrase(_ battery: BatteryReport) -> String {
        if condition.lowPowerMode {
            return "Low Power Mode on"
        }
        return switch battery.charging {
        case .onBattery: "On battery"
        case .charging: "Charging"
        case .pluggedInNotCharging: "Plugged in, not charging"
        case .charged: "Charged"
        }
    }

    private func drawSource(_ battery: BatteryReport) -> String {
        if battery.charging == .onBattery {
            return "From the battery"
        }
        return battery.adapterWatts.map { "From the \($0) W adapter" } ?? "From the adapter"
    }

    private func batterySymbol(_ battery: BatteryReport) -> String {
        switch battery.charging {
        case .charging: "battery.100percent.bolt"
        case .onBattery: battery.percent <= 20 ? "battery.25percent" : "battery.75percent"
        case .pluggedInNotCharging, .charged: "battery.100percent"
        }
    }
}
