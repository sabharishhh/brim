import BrimCore
import Foundation
import GRDB

// swiftformat:disable wrapMultilineStatementBraces

extension Index {
    /// App installations, removals and version changes observed in a time
    /// window. Repeated unchanged looks keep the events, while older events
    /// fall out of the window. Each adjacent pair remains its own comparison.
    public nonisolated func recentChanges(since start: Date, until end: Date = Date()) async throws -> [InstallChange] {
        guard start <= end else { return [] }
        return try await dbManager.dbPool.read { database in
            let scans = try Row.fetchAll(database, sql: """
            SELECT scan_id, MAX(observed_at) AS at, MAX(id) AS seq FROM observation
            WHERE scan_id IS NOT NULL GROUP BY scan_id ORDER BY seq DESC
            """)
            guard scans.count > 1 else { return [] }
            let firsts = try Row.fetchAll(database, sql: """
            SELECT identity_id, MIN(id) AS first FROM observation
            WHERE scan_id IS NOT NULL GROUP BY identity_id
            """)
            let firstSeen = Dictionary(uniqueKeysWithValues: firsts.map { row in
                (row["identity_id"] as String, row["first"] as Int64)
            })
            var cached: [String: [String: InstallObservation]] = [:]
            func snapshot(_ scanID: String) throws -> [String: InstallObservation] {
                if let existing = cached[scanID] {
                    return existing
                }
                let read = try Self.snapshot(database, scanID: scanID)
                cached[scanID] = read
                return read
            }
            var result: [InstallChange] = []
            for position in 1 ..< scans.count {
                let observed: Date = scans[position - 1]["at"]
                guard observed >= start, observed <= end else { continue }
                let currentScan: String = scans[position - 1]["scan_id"]
                let previousScan: String = scans[position]["scan_id"]
                let previousLook: Date = scans[position]["at"]
                let previousSequence: Int64 = scans[position]["seq"]
                let current = try snapshot(currentScan)
                let previous = try snapshot(previousScan)
                for change in Self.difference(from: previous, to: current, since: previousLook, until: observed,
                                              growthThreshold: .max) {
                    let observation = current[change.bundleID] ?? previous[change.bundleID]
                    guard Self.isAppEvent(
                        change, observation: observation, firstSeen: firstSeen[change.bundleID],
                        previousSequence: previousSequence, previousLook: previousLook
                    ) else { continue }
                    result.append(InstallChange(kind: change.kind, bundleID: change.bundleID, name: change.name,
                                                since: change.since, until: change.until, snapshotID: currentScan))
                }
            }
            return result
        }
    }

    private static func isAppEvent(_ change: InstallChange, observation: InstallObservation?,
                                   firstSeen: Int64?, previousSequence: Int64, previousLook: Date) -> Bool {
        switch change.kind {
        case .appeared, .disappeared: break
        case let .updated(oldVersion, newVersion):
            guard oldVersion?.isEmpty == false, newVersion?.isEmpty == false else { return false }
        case .grew, .shrank: return false
        }
        guard observation.map(isIndependentApplication) ?? false else { return false }
        if change.kind == .appeared,
           firstSeen.map({ $0 > previousSequence }) ?? true,
           let added = observation?.addedAt, added < previousLook {
            // A newly discovered old bundle is not a new installation.
            return false
        }
        return true
    }

    private static func isIndependentApplication(_ observation: InstallObservation) -> Bool {
        guard let path = observation.bundlePath else { return true }
        let protected = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]
        guard !protected.contains(where: path.hasPrefix) else { return false }
        return !URL(fileURLWithPath: path).deletingLastPathComponent().pathComponents.contains { $0.hasSuffix(".app") }
    }
}
