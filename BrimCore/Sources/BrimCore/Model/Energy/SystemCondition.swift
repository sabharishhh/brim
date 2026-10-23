import Foundation
import IOKit.ps

/// How the Mac is coping, from documented public APIs only. A temperature in
/// degrees would need private, undocumented interfaces, and the question a
/// person has is whether the Mac is slowing down to cool itself, which
/// `ProcessInfo.thermalState` answers.
public struct SystemCondition: Sendable, Equatable {

    public enum Thermal: Sendable, Equatable {
        case normal
        case slightlyElevated
        case hot
        case tooHot

        /// Apple's `ProcessInfo.ThermalState`, in the same order.
        public static func of(_ state: ProcessInfo.ThermalState) -> Thermal {
            switch state {
            case .nominal: return .normal
            case .fair: return .slightlyElevated
            case .serious: return .hot
            case .critical: return .tooHot
            @unknown default: return .normal
            }
        }

        public var title: String {
            switch self {
            case .normal: return "Normal"
            case .slightlyElevated: return "Slightly warm"
            case .hot: return "Running hot"
            case .tooHot: return "Too hot"
            }
        }

        /// What each state means, taken from Apple's Energy Efficiency Guide.
        public var meaning: String {
            switch self {
            case .normal:
                return "Running at full speed."
            case .slightlyElevated:
                return "A little warm. No slowdown yet."
            case .hot:
                return "The Mac is slowing down to cool off."
            case .tooHot:
                return "Very hot. The Mac is slowing down sharply to cool off."
            }
        }

        public var symbolName: String {
            switch self {
            case .normal: return "thermometer.low"
            case .slightlyElevated: return "thermometer.medium"
            case .hot: return "thermometer.high"
            case .tooHot: return "thermometer.sun.fill"
            }
        }

        /// Whether this is worth drawing attention to.
        public var isNoteworthy: Bool { self == .hot || self == .tooHot }
    }

    public enum Power: Sendable, Equatable {
        case battery(percent: Int)
        case chargingFromAdapter(percent: Int)
        case adapterOnly

        public var title: String {
            switch self {
            case .battery(let percent): return "On battery, \(percent)%"
            case .chargingFromAdapter(let percent): return "Charging, \(percent)%"
            case .adapterOnly: return "Plugged in"
            }
        }

        public var symbolName: String {
            switch self {
            case .battery(let percent):
                return percent <= 20 ? "battery.25" : "battery.100"
            case .chargingFromAdapter: return "battery.100.bolt"
            case .adapterOnly: return "powerplug"
            }
        }

        /// Whether what an app is doing costs anything right now. On the adapter it
        /// does not, so the panel does not warn.
        public var isOnBattery: Bool {
            if case .battery = self { return true }
            return false
        }
    }

    public let thermal: Thermal
    public let power: Power?
    /// Apple's own switch for trading speed against battery.
    public let lowPowerMode: Bool

    public init(thermal: Thermal, power: Power?, lowPowerMode: Bool) {
        self.thermal = thermal
        self.power = power
        self.lowPowerMode = lowPowerMode
    }

    public static func current(
        processInfo: ProcessInfo = .processInfo,
        powerSource: () -> Power? = SystemCondition.readPowerSource
    ) -> SystemCondition {
        SystemCondition(
            thermal: Thermal.of(processInfo.thermalState),
            power: powerSource(),
            lowPowerMode: processInfo.isLowPowerModeEnabled
        )
    }

    /// `IOPSCopyPowerSourcesInfo`. Nil on a Mac with no battery.
    public static func readPowerSource() -> Power? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : 0
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

            if isCharging { return .chargingFromAdapter(percent: percent) }
            return onAC ? .adapterOnly : .battery(percent: percent)
        }
        return nil
    }

    /// One line, or nil when there is nothing worth saying, which is the common
    /// case.
    public var note: String? {
        if thermal.isNoteworthy { return thermal.meaning }
        if lowPowerMode {
            return "Low Power Mode is on. The Mac runs slower to save battery."
        }
        if case .battery(let percent) = power, percent <= 20 {
            return "The battery is running low."
        }
        return nil
    }
}
