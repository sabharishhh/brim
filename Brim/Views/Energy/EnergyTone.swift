import BrimCore
import SwiftUI

/// Energy's status colours, always beside a word. Battery: green normally,
/// yellow in Low Power Mode as macOS draws it, red at 20% or less on battery.
/// Temperature follows the thermal state: blue at full speed, orange when
/// warm, red once it slows down to cool.
enum EnergyTone {
    static func battery(percent: Int, onBattery: Bool, lowPowerMode: Bool) -> Color {
        if onBattery, percent <= 20 {
            return Palette.destructive
        }
        return lowPowerMode ? Palette.lowPower : Palette.success
    }

    static func thermal(_ thermal: SystemCondition.Thermal) -> Color {
        switch thermal {
        case .normal: Palette.info
        case .slightlyElevated: Palette.caution
        case .hot, .tooHot: Palette.destructive
        }
    }

    /// Short enough for a card's line.
    static func thermalPhrase(_ thermal: SystemCondition.Thermal) -> String {
        thermal == .normal ? "Normal temperature" : thermal.title
    }
}
