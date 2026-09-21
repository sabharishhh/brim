import Foundation
import BrimCore

/// Writing down what is registered, before anything deregisters it.
///
/// The capture has one job that matters more than completeness: knowing
/// when it is *not* complete. `BTMStore.records()` returns nil when the
/// store could not be read, which is a different answer from an empty
/// list and almost always means Full Disk Access is off. A capture that
/// treated the two the same would hand back an empty restore list, the
/// reset would look safe, and the person would find out what they had
/// lost when things stopped starting.
public struct BTMRestoreCapture: Sendable {

    private let read: @Sendable () -> [BTMRecord]?

    public init(read: @escaping @Sendable () -> [BTMRecord]? = { BTMStore().records() }) {
        self.read = read
    }

    /// Everything currently registered, or an explicit account of why the
    /// list is not trustworthy.
    public func capture(now: Date = Date()) -> BTMRestoreList {
        guard let records = read() else {
            return BTMRestoreList(
                capturedAt: now, entries: [], isComplete: false,
                gap: "Brim could not read the background item store, which usually means "
                   + "Full Disk Access is switched off"
            )
        }

        let entries = records
            .map(Self.entry(from:))
            .sorted { ($0.name, $0.bundleIdentifier ?? "") < ($1.name, $1.bundleIdentifier ?? "") }

        return BTMRestoreList(capturedAt: now, entries: entries, isComplete: true)
    }

    static func entry(from record: BTMRecord) -> BTMRestoreList.Entry {
        BTMRestoreList.Entry(
            name: record.name
                ?? record.bundleIdentifier
                ?? record.identifier
                ?? "an unnamed background item",
            developer: record.developerName,
            bundleIdentifier: record.bundleIdentifier,
            // Only an absolute path is worth writing down. A relative one
            // is meaningless without its parent, and a restore list is
            // read by a person hours later with no parent to hand.
            path: record.url?.path,
            type: record.type,
            wasEnabled: isEnabled(record)
        )
    }

    /// Whether macOS currently has this one switched on.
    ///
    /// The disposition is a bitfield the store writes as a string. Bit 0
    /// is enabled, and re-enabling something the person had deliberately
    /// switched off would be its own small betrayal, so it is recorded
    /// rather than assumed.
    static func isEnabled(_ record: BTMRecord) -> Bool {
        guard let disposition = record.disposition else { return true }
        if let bits = Int(disposition) { return bits & 1 == 1 }
        let lowered = disposition.lowercased()
        if lowered.contains("disabled") { return false }
        if lowered.contains("enabled") { return true }
        return true
    }
}
