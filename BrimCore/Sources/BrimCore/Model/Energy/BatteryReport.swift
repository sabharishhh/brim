import Foundation
import IOKit
import IOKit.ps

/// The battery now, and what the whole Mac is drawing. Every figure is read
/// the way System Settings reads it, so Brim never disagrees with it:
/// condition, capacity and cycles come from `system_profiler`, not the raw
/// registry. Nothing looks forward: Brim never turns the charge into a time.
public struct BatteryReport: Sendable, Equatable {
    public enum Charging: Sendable, Equatable {
        case onBattery
        case charging
        /// On the adapter and holding its charge: a charge limit or Optimized
        /// Battery Charging.
        case pluggedInNotCharging
        case charged
    }

    public struct Health: Sendable, Equatable {
        /// Worded as System Settings words it: Normal, or Service
        /// Recommended.
        public let condition: String
        public let needsService: Bool
        /// Percent of the capacity the battery had when new.
        public let maximumCapacity: Int?
        public let cycles: Int?

        public init(condition: String, needsService: Bool, maximumCapacity: Int?, cycles: Int?) {
            self.condition = condition
            self.needsService = needsService
            self.maximumCapacity = maximumCapacity
            self.cycles = cycles
        }
    }

    public let percent: Int
    public let charging: Charging
    /// The whole Mac's draw, from the battery controller's own telemetry.
    /// Nil where the Mac does not report it.
    public let drawWatts: Double?
    /// The connected adapter's rating, when one is connected.
    public let adapterWatts: Int?
    public let health: Health?

    public init(percent: Int, charging: Charging, drawWatts: Double?, adapterWatts: Int?, health: Health?) {
        self.percent = percent
        self.charging = charging
        self.drawWatts = drawWatts
        self.adapterWatts = adapterWatts
        self.health = health
    }

    // MARK: - Reading

    /// Nil on a Mac with no battery.
    public static func current() -> BatteryReport? {
        read(powerSource: internalBattery(), registry: smartBattery(), profiler: profilerOutput())
    }

    /// Assembles the report from three readings. A missing reading drops its
    /// own facts and nothing else.
    public static func read(
        powerSource: [String: Any]?, registry: [String: Any]?, profiler: Data?
    ) -> BatteryReport? {
        guard let source = powerSource else { return nil }
        let current = source[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = source[kIOPSMaxCapacityKey] as? Int ?? 100
        let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : 0
        let onAdapter = (source[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let isCharging = source[kIOPSIsChargingKey] as? Bool ?? false
        let isCharged = source[kIOPSIsChargedKey] as? Bool ?? false

        let charging: Charging = if isCharging {
            .charging
        } else if !onAdapter {
            .onBattery
        } else {
            isCharged || percent >= 100 ? .charged : .pluggedInNotCharging
        }

        let telemetry = registry?["PowerTelemetryData"] as? [String: Any]
        let load = (telemetry?["SystemLoad"] as? NSNumber)?.doubleValue
        let adapter = (registry?["AdapterDetails"] as? [String: Any])?["Watts"] as? Int

        return BatteryReport(
            percent: percent,
            charging: charging,
            drawWatts: load.flatMap { $0 > 0 ? $0 / 1000 : nil },
            adapterWatts: onAdapter ? adapter.flatMap { $0 > 0 ? $0 : nil } : nil,
            health: profiler.flatMap(health(fromProfiler:))
        )
    }

    /// The health section of `system_profiler SPPowerDataType -json`.
    static func health(fromProfiler data: Data) -> Health? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["SPPowerDataType"] as? [[String: Any]],
              let info = entries.lazy.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first
        else { return nil }

        let reported = info["sppower_battery_health"] as? String
        // Settings shows "Normal" for what the profiler calls "Good", and
        // "Service Recommended" for anything else.
        let good = reported?.caseInsensitiveCompare("Good") == .orderedSame
        let capacity = (info["sppower_battery_health_maximum_capacity"] as? String)
            .flatMap { Int($0.filter(\.isNumber)) }
        let cycles = info["sppower_battery_cycle_count"] as? Int
        guard reported != nil || capacity != nil || cycles != nil else { return nil }
        return Health(
            condition: reported == nil ? "Unknown" : (good ? "Normal" : "Service Recommended"),
            needsService: reported != nil && !good,
            maximumCapacity: capacity,
            cycles: cycles
        )
    }

    // MARK: - Sources

    /// `IOPSCopyPowerSourcesInfo`, the documented way to ask.
    static func internalBattery() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            return description
        }
        return nil
    }

    /// The battery controller's registry entry, for the whole Mac's draw
    /// and the adapter's rating. Readable without privileges.
    static func smartBattery() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    /// About a tenth of a second on this Mac.
    static func profilerOutput() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
