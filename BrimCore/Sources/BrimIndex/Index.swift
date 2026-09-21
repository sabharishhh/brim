import Foundation
import GRDB
import BrimCore

/// A concurrency-safe coordinator for the database.
/// Manages writes sequentially using actor isolation, while exposing concurrent read paths.
public actor Index {
    private let dbManager: DatabaseManager
    
    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }
    
    /// Inserts a batch of discovered apps, updating their identity and evidence records.
    public func recordScan(apps: [any AppArtifact]) async throws {
        try await dbManager.dbPool.write { db in
            for app in apps {
                let identityID = app.bundleID
                
                // 1. Upsert Identity
                try db.execute(
                    sql: """
                    INSERT INTO identity (id, bundle_id, name)
                    VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name
                    """,
                    arguments: [identityID, app.bundleID, app.name]
                )
                
                // 2. Clear old evidence (a new scan completely replaces prior evidence state)
                try db.execute(sql: "DELETE FROM evidence WHERE identity_id = ?", arguments: [identityID])
                
                // 3. Insert new evidence
                for ev in app.evidence {
                    try db.execute(
                        sql: """
                        INSERT INTO evidence (identity_id, url, tier, mechanism, human_sentence)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [identityID, ev.url.path, ev.tier.rawValue, ev.mechanism, ev.humanSentence]
                    )
                }
            }
        }
    }
    
    /// Writes one snapshot of what is installed. Nothing is ever updated
    /// or deleted here.
    ///
    /// Append-only is not tidiness. A row that is overwritten cannot be
    /// subtracted from, so "what changed since last time" would need a
    /// process watching for changes, and a resident watcher is the thing
    /// every competitor ships and nobody wants: it costs battery, it
    /// needs permissions, and it is one more daemon on a Mac whose whole
    /// complaint is that it has too many. Two snapshots and a difference
    /// answer the same question for nothing.
    @discardableResult
    public func recordInstalled(
        _ applications: [InstallObservation], at moment: Date = Date()
    ) async throws -> String {
        let scanID = UUID().uuidString
        try await dbManager.dbPool.write { db in
            for application in applications {
                try db.execute(
                    sql: """
                    INSERT INTO identity (id, bundle_id, name)
                    VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name
                    """,
                    arguments: [application.bundleID, application.bundleID, application.name]
                )
                try db.execute(
                    sql: """
                    INSERT INTO observation
                        (identity_id, observed_at, state, scan_id, version,
                         bundle_path, size_bytes, added_at, last_used_at)
                    VALUES (?, ?, 'installed', ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        application.bundleID, moment, scanID, application.version,
                        application.bundlePath, application.sizeBytes,
                        application.addedAt, application.lastUsedAt,
                    ]
                )
            }
        }
        return scanID
    }

    /// The two most recent snapshots, subtracted.
    ///
    /// Empty when there is only one, which is the honest answer on a
    /// first run: nothing has changed because there is nothing to
    /// compare against, and inventing a list of "new" applications the
    /// first time somebody opens Brim would be a lie that makes every
    /// later list untrustworthy.
    public nonisolated func changesSinceLastScan(
        growthThreshold: Int64 = 50 * 1024 * 1024
    ) async throws -> [InstallChange] {
        try await dbManager.dbPool.read { db in
            // Ordered by the rowid, not by the timestamp. Two scans a
            // second apart share a stored `observed_at` at this
            // resolution, and ordering on it then picks between them
            // arbitrarily: "what changed" came back with the growth
            // inverted and with a comparison against the wrong snapshot.
            // The autoincrement is monotonic whatever the clock does.
            let scans = try Row.fetchAll(db, sql: """
                SELECT scan_id, MAX(observed_at) AS at, MAX(id) AS seq FROM observation
                WHERE scan_id IS NOT NULL
                GROUP BY scan_id ORDER BY seq DESC LIMIT 2
                """)
            guard scans.count == 2 else { return [] }

            let latest = try Self.snapshot(db, scanID: scans[0]["scan_id"])
            let previous = try Self.snapshot(db, scanID: scans[1]["scan_id"])
            let since: Date = scans[1]["at"]
            let until: Date = scans[0]["at"]

            var changes: [InstallChange] = []

            for (bundleID, now) in latest {
                guard let before = previous[bundleID] else {
                    changes.append(InstallChange(
                        kind: .appeared, bundleID: bundleID, name: now.name,
                        since: since, until: until
                    ))
                    continue
                }
                if before.version != now.version {
                    changes.append(InstallChange(
                        kind: .updated(from: before.version, to: now.version),
                        bundleID: bundleID, name: now.name, since: since, until: until
                    ))
                    continue
                }
                // Size only counts when the version did not move. An
                // update that grew is just an update, and saying both
                // would be two rows for one event.
                if let old = before.sizeBytes, let new = now.sizeBytes {
                    let delta = new - old
                    if delta >= growthThreshold {
                        changes.append(InstallChange(
                            kind: .grew(by: delta), bundleID: bundleID, name: now.name,
                            since: since, until: until
                        ))
                    } else if -delta >= growthThreshold {
                        changes.append(InstallChange(
                            kind: .shrank(by: -delta), bundleID: bundleID, name: now.name,
                            since: since, until: until
                        ))
                    }
                }
            }

            for (bundleID, before) in previous where latest[bundleID] == nil {
                changes.append(InstallChange(
                    kind: .disappeared, bundleID: bundleID, name: before.name,
                    since: since, until: until
                ))
            }

            return changes.sorted { $0.name < $1.name }
        }
    }

    private static func snapshot(
        _ db: Database, scanID: String
    ) throws -> [String: InstallObservation] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT o.identity_id, o.version, o.bundle_path, o.size_bytes,
                   o.added_at, o.last_used_at, o.observed_at, i.name
            FROM observation o JOIN identity i ON i.id = o.identity_id
            WHERE o.scan_id = ?
            """, arguments: [scanID])

        var result: [String: InstallObservation] = [:]
        for row in rows {
            let bundleID: String = row["identity_id"]
            result[bundleID] = InstallObservation(
                bundleID: bundleID,
                name: row["name"],
                version: row["version"],
                bundlePath: row["bundle_path"],
                sizeBytes: row["size_bytes"],
                addedAt: row["added_at"],
                lastUsedAt: row["last_used_at"],
                observedAt: row["observed_at"]
            )
        }
        return result
    }

    /// How many snapshots are on record, so the UI can say "first look"
    /// rather than "nothing changed".
    public nonisolated func snapshotCount() async throws -> Int {
        try await dbManager.dbPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT scan_id) FROM observation WHERE scan_id IS NOT NULL
                """) ?? 0
        }
    }

    /// Reads identities asynchronously without blocking the actor's write thread.
    public nonisolated func fetchIdentity(bundleID: String) async throws -> String? {
        try await dbManager.dbPool.read { db in
            return try String.fetchOne(db, sql: "SELECT name FROM identity WHERE bundle_id = ?", arguments: [bundleID])
        }
    }
}
