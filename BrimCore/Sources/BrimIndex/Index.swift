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
    
    /// Reads identities asynchronously without blocking the actor's write thread.
    public nonisolated func fetchIdentity(bundleID: String) async throws -> String? {
        try await dbManager.dbPool.read { db in
            return try String.fetchOne(db, sql: "SELECT name FROM identity WHERE bundle_id = ?", arguments: [bundleID])
        }
    }
}
