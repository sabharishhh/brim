import Foundation
import IOKit

/// What a full battery holds, so energy can be said as a share of one.
///
/// A number of joules means nothing to a person. "Four per cent of a full
/// charge" means something immediately, and it is the same number divided
/// by something the Mac already knows about itself.
///
/// Read from `AppleSmartBattery`: design capacity in milliamp-hours and
/// the pack voltage in millivolts. Design rather than current capacity on
/// purpose, because the question is what this software costs, not how
/// worn the battery is, and a share that grows as a battery ages would
/// make the same application look worse every year for no reason.
public struct BatteryCapacity: Equatable, Sendable {
    /// What the battery was built to hold.
    public let designMilliwattHours: Double

    public init(designMilliwattHours: Double) {
        self.designMilliwattHours = designMilliwattHours
    }

    /// This Mac's battery, or nil on a machine that has none.
    ///
    /// A desktop is not a failure to read. It has no battery, so a share
    /// of one is not a thing that can be said, and the view says the
    /// energy in milliwatt-hours and stops there.
    public static func current() -> BatteryCapacity? {
        let match = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
                == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any]
        else { return nil }

        return from(registry: values)
    }

    /// Split out so the arithmetic can be checked without a battery.
    ///
    /// The design capacity moved: it used to sit at the top level and now
    /// lives inside `BatteryData` on this machine, so both are read and
    /// the nested one wins. Millivolts and milliamp-hours multiply to
    /// microwatt-hours, hence the thousand.
    static func from(registry: [String: Any]) -> BatteryCapacity? {
        let nested = registry["BatteryData"] as? [String: Any]
        let capacity = (nested?["DesignCapacity"] as? Int)
            ?? (registry["DesignCapacity"] as? Int)
        let millivolts = (registry["Voltage"] as? Int) ?? (nested?["Voltage"] as? Int)

        guard let capacity, capacity > 0, let millivolts, millivolts > 0 else { return nil }
        return BatteryCapacity(
            designMilliwattHours: Double(capacity) * Double(millivolts) / 1000
        )
    }

    /// What share of a full charge this much energy is, as a percentage.
    public func share(ofMilliwattHours energy: Double) -> Double {
        guard designMilliwattHours > 0 else { return 0 }
        return energy / designMilliwattHours * 100
    }

    /// Said the way a person would, or nil when it is too small to matter.
    ///
    /// Deliberately not a predicted battery life. The specification
    /// forbids projecting forward in time units and it is right to: the
    /// projection depends on what the machine does next, which nobody
    /// knows, and a number of minutes reads as a promise.
    public func sentence(forMilliwattHours energy: Double) -> String? {
        let percentage = share(ofMilliwattHours: energy)
        guard percentage >= 0.1 else { return nil }
        return String(format: "%.1f%% of a full charge", percentage)
    }
}
