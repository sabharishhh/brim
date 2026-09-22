import Foundation
import IOKit.ps

/// How the Mac is coping, from the interfaces Apple publishes for it.
///
/// Everything here is a documented public API. That is a deliberate
/// constraint rather than a shortage of ambition: every tool that prints a
/// CPU temperature in degrees on Apple Silicon reads it through
/// `IOHIDEventSystemClient` or raw SMC keys, both private, both undocumented,
/// and both liable to change in a September release. Apple has never shown a
/// temperature anywhere in macOS, including in Activity Monitor.
///
/// What Apple does publish is `ProcessInfo.thermalState`, and it answers the
/// question a person actually has. Nobody wants to know that a core is at
/// 87 degrees. They want to know whether the Mac is being slowed down to
/// cool itself, which is what thermal state says, in Apple's own terms, with
/// Apple's own meanings behind them.
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

        /// What it means for the person, taken from Apple's own description
        /// of each state in the Energy Efficiency Guide rather than invented.
        public var meaning: String {
            switch self {
            case .normal:
                return "The Mac is running at full speed with room to spare."
            case .slightlyElevated:
                return "A little warm. Nothing is being slowed down yet."
            case .hot:
                return "The Mac is throttling itself to cool down, so things will feel slower."
            case .tooHot:
                return "The Mac is very hot and is cutting performance hard to protect itself."
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

        /// Whether what an app is doing right now costs the person anything.
        /// On the adapter it does not, and saying so stops the panel reading
        /// as a warning when there is nothing to warn about.
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

    /// `IOPSCopyPowerSourcesInfo`, which is the documented way to ask.
    ///
    /// Returns nil on a machine with no battery, where "on battery" is not a
    /// thing that can be said.
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

    /// One line, or nil when there is nothing worth saying.
    ///
    /// Silence is the common case and the right one. A Mac that is cool, on
    /// the adapter and not throttling has nothing to report, and a card that
    /// insists on saying so every time teaches people to stop reading it.
    public var note: String? {
        if thermal.isNoteworthy { return thermal.meaning }
        if lowPowerMode {
            return "Low Power Mode is on, so the Mac is deliberately running slower to last longer."
        }
        if case .battery(let percent) = power, percent <= 20 {
            return "Running low, so what is drawing power matters more than usual."
        }
        return nil
    }
}
