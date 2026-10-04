import Foundation
import GRDB
import BrimCore

/// A concurrency-safe coordinator for the database.
/// Manages writes sequentially using actor isolation, while exposing concurrent read paths.
public actor Index {
    let dbManager: DatabaseManager
    
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

    /// The version an application had in the last snapshot taken before
    /// `moment`, or nil when no snapshot saw it before then.
    public nonisolated func version(of bundleID: String, before moment: Date) async throws -> String? {
        try await dbManager.dbPool.read { db in
            try String.fetchOne(db, sql: """
                SELECT version FROM observation
                WHERE identity_id = ? AND observed_at < ? AND version IS NOT NULL
                ORDER BY id DESC LIMIT 1
                """, arguments: [bundleID, moment])
        }
    }

    /// The most recent change: the latest two snapshots that differ,
    /// subtracted.
    ///
    /// Empty when there is only one, which is the honest answer on a
    /// first run: nothing has changed because there is nothing to
    /// compare against, and inventing a list of "new" applications the
    /// first time somebody opens Brim would be a lie that makes every
    /// later list untrustworthy.
    ///
    /// Not simply the last two. Every launch takes a snapshot, so a
    /// relaunch compared two identical ones and Home's Changes emptied
    /// each time Brim opened. Each change carries the two moments it fell
    /// between, so an older change still says when it happened.
    public nonisolated func changesSinceLastScan(
        growthThreshold: Int64 = 50 * 1024 * 1024, lookBack: Int = 60
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
                GROUP BY scan_id ORDER BY seq DESC LIMIT ?
                """, arguments: [lookBack])
            guard scans.count >= 2 else { return [] }

            var later = try Self.snapshot(db, scanID: scans[0]["scan_id"])
            for index in 1..<scans.count {
                let earlier = try Self.snapshot(db, scanID: scans[index]["scan_id"])
                let changes = Self.difference(
                    from: earlier, to: later, since: scans[index]["at"], until: scans[index - 1]["at"],
                    growthThreshold: growthThreshold
                )
                if !changes.isEmpty { return changes }
                later = earlier
            }
            return []
        }
    }

    static func difference(
        from previous: [String: InstallObservation], to latest: [String: InstallObservation],
        since: Date, until: Date, growthThreshold: Int64
    ) -> [InstallChange] {
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

    static func snapshot(
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

    /// When each currently installed application began its latest recorded
    /// period on the disk. A reinstall starts another period.
    ///
    /// An application in the first snapshot has no appearance date: it was
    /// already installed, and nothing Brim recorded says when it arrived.
    /// By rowid, for the reason `changesSinceLastScan` gives.
    public nonisolated func appearances() async throws -> [String: Date] {
        try await appearanceWindows().mapValues(\.seen)
    }

    /// For each app's current installed period: when it began, and when
    /// Brim had last looked before that. An app
    /// whose bundle was already on the disk before that earlier look was
    /// not installed in between; the list simply had not included it.
    public nonisolated func appearanceWindows() async throws -> [String: AppearanceWindow] {
        try await dbManager.dbPool.read { database in
            // Absence and order are facts about snapshots, not timestamps.
            // Select only current apps' period starts instead of loading
            // every historical observation into the process.
            let rows = try Row.fetchAll(database, sql: """
            WITH scans AS (
                SELECT scan_id, MAX(observed_at) AS at, MAX(id) AS last_row
                FROM observation WHERE scan_id IS NOT NULL GROUP BY scan_id
            ), current AS (
                SELECT DISTINCT identity_id FROM observation
                WHERE scan_id = (SELECT scan_id FROM scans ORDER BY last_row DESC LIMIT 1)
            ), periods AS (
                SELECT current.identity_id, (
                    SELECT MAX(scans.last_row) FROM scans WHERE NOT EXISTS (
                        SELECT 1 FROM observation o
                        WHERE o.scan_id = scans.scan_id AND o.identity_id = current.identity_id
                    )
                ) AS last_absent FROM current
            ), starts AS (
                SELECT periods.identity_id, periods.last_absent, (
                    SELECT MIN(o.id) FROM observation o
                    WHERE o.identity_id = periods.identity_id AND o.scan_id IS NOT NULL
                        AND o.id > periods.last_absent
                ) AS first_row FROM periods WHERE periods.last_absent IS NOT NULL
            )
            SELECT o.identity_id, o.observed_at, o.added_at, (
                SELECT scans.at FROM scans WHERE scans.last_row < o.id
                ORDER BY scans.last_row DESC LIMIT 1
            ) AS previous_look, EXISTS (
                SELECT 1 FROM observation earlier
                WHERE earlier.identity_id = o.identity_id AND earlier.scan_id IS NOT NULL
                    AND earlier.id < starts.last_absent
            ) AS reinstalled
            FROM starts JOIN observation o ON o.id = starts.first_row
            """)
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["identity_id"] as String, AppearanceWindow(
                    seen: row["observed_at"], previousLook: row["previous_look"],
                    addedAt: row["added_at"], isReinstallation: row["reinstalled"]
                ))
            })
        }
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

    /// Applications an earlier snapshot saw that the latest did not, by
    /// bundle identifier, with the last time one was seen. macOS's own are
    /// left out.
    public nonisolated func removedApplications() async throws -> [String: Date] {
        try await dbManager.dbPool.read { db in
            guard let latest = try String.fetchOne(db, sql: """
                SELECT scan_id FROM observation WHERE scan_id IS NOT NULL ORDER BY id DESC LIMIT 1
                """) else { return [:] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT identity_id, MAX(observed_at) AS seen FROM observation
                WHERE scan_id IS NOT NULL AND identity_id NOT IN (
                    SELECT identity_id FROM observation WHERE scan_id = ?)
                GROUP BY identity_id
                """, arguments: [latest])
            var removed: [String: Date] = [:]
            for row in rows {
                guard let id: String = row["identity_id"], let seen: Date = row["seen"],
                      !id.lowercased().hasPrefix("com.apple.") else { continue }
                removed[id] = seen
            }
            return removed
        }
    }

    /// Where Brim last saw each of these applications, by bundle
    /// identifier. Only the last place: an app that moved away from a path
    /// before it was removed was not replaced by whatever is there now.
    public nonisolated func lastBundlePaths(of identifiers: [String]) async throws -> [String: String] {
        guard !identifiers.isEmpty else { return [:] }
        return try await dbManager.dbPool.read { db in
            var paths: [String: String] = [:]
            for id in identifiers {
                if let path = try String.fetchOne(db, sql: """
                    SELECT bundle_path FROM observation
                    WHERE identity_id = ? AND bundle_path IS NOT NULL
                    ORDER BY id DESC LIMIT 1
                    """, arguments: [id]) {
                    paths[id] = path
                }
            }
            return paths
        }
    }

    /// Every name Brim has recorded for an application, by bundle
    /// identifier, including applications that have since been removed.
    public nonisolated func recordedNames() async throws -> [String: String] {
        try await dbManager.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT bundle_id, name FROM identity WHERE bundle_id IS NOT NULL")
            var names: [String: String] = [:]
            for row in rows {
                if let id: String = row["bundle_id"], let name: String = row["name"], !name.isEmpty {
                    names[id.lowercased()] = name
                }
            }
            return names
        }
    }

    /// Reads identities asynchronously without blocking the actor's write thread.
    public nonisolated func fetchIdentity(bundleID: String) async throws -> String? {
        try await dbManager.dbPool.read { db in
            return try String.fetchOne(db, sql: "SELECT name FROM identity WHERE bundle_id = ?", arguments: [bundleID])
        }
    }
}

/// When an app's current installed period began, and when Brim had last
/// looked before that. The first bundle's added date keeps later updates
/// from turning an old discovery into a new installation.
public struct AppearanceWindow: Sendable, Equatable {
    public let seen: Date
    public let previousLook: Date
    public let addedAt: Date?
    public let isReinstallation: Bool

    public init(seen: Date, previousLook: Date, addedAt: Date? = nil, isReinstallation: Bool = false) {
        self.seen = seen
        self.previousLook = previousLook
        self.addedAt = addedAt
        self.isReinstallation = isReinstallation
    }
}
