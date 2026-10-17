import BrimCore
import Foundation
import GRDB

public extension Index {
    /// Inserts a batch of discovered apps, updating their identity and evidence records.
    func recordScan(apps: [any AppArtifact]) async throws {
        try await dbManager.dbPool.write { database in
            for app in apps {
                let identityID = app.bundleID

                // 1. Upsert Identity
                try database.execute(
                    sql: """
                    INSERT INTO identity (id, bundle_id, name)
                    VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name
                    """,
                    arguments: [identityID, app.bundleID, app.name]
                )

                // 2. Clear old evidence (a new scan completely replaces prior evidence state)
                try database.execute(sql: "DELETE FROM evidence WHERE identity_id = ?", arguments: [identityID])

                // 3. Insert new evidence
                for evidence in app.evidence {
                    try database.execute(
                        sql: """
                        INSERT INTO evidence (identity_id, url, tier, mechanism, human_sentence)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            identityID,
                            evidence.url.path,
                            evidence.tier.rawValue,
                            evidence.mechanism,
                            evidence.humanSentence
                        ]
                    )
                }
            }
        }
    }

    /// Writes one snapshot of what is installed. Nothing here is ever updated or
    /// deleted: an overwritten row cannot be subtracted from, and "what changed"
    /// would then need a resident watcher, which costs battery and permissions.
    @discardableResult
    func recordInstalled(
        _ applications: [InstallObservation], at moment: Date = Date()
    ) async throws -> String {
        let scanID = UUID().uuidString
        try await dbManager.dbPool.write { database in
            for application in applications {
                try database.execute(
                    sql: """
                    INSERT INTO identity (id, bundle_id, name, names)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name,
                        names = COALESCE(excluded.names, identity.names)
                    """,
                    arguments: [application.bundleID, application.bundleID, application.name,
                                Self.encodedNames(application.names)]
                )
                try database.execute(
                    sql: """
                    INSERT INTO observation
                        (identity_id, observed_at, state, scan_id, version,
                         bundle_path, size_bytes, added_at, last_used_at)
                    VALUES (?, ?, 'installed', ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        application.bundleID, moment, scanID, application.version,
                        application.bundlePath, application.sizeBytes,
                        application.addedAt, application.lastUsedAt
                    ]
                )
            }
        }
        return scanID
    }

    /// The names as one JSON array, or nothing when there are none, so a
    /// snapshot that learned nothing keeps what was recorded before.
    internal static func encodedNames(_ names: [String]) -> String? {
        guard !names.isEmpty, let data = try? JSONEncoder().encode(names) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }
}
