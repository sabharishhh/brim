import Foundation
import GRDB

public struct DatabaseManager: Sendable {
    public let dbPool: DatabasePool
    
    /// Initializes the database pool at the given URL, rebuilding if corrupt.
    public init(databaseURL: URL) throws {
        var configuration = Configuration()
        // WAL mode is default for DatabasePool, but we can be explicit.
        
        var pool: DatabasePool?
        do {
            pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
            // Attempt to read from it to ensure it's not corrupt
            try pool?.read { db in
                _ = try String.fetchOne(db, sql: "PRAGMA schema_version")
            }
        } catch {
            // Corrupt or unreadable. Nuke it and recreate.
            try? FileManager.default.removeItem(at: databaseURL)
            // Also remove WAL and SHM
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            
            pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        }
        
        self.dbPool = pool!
        
        try migrate()
    }
    
    private func migrate() throws {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("v1") { db in
            // meta
            try db.create(table: "meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
            
            // identity
            try db.create(table: "identity") { t in
                t.column("id", .text).primaryKey() // hash or canonical name
                t.column("bundle_id", .text)
                t.column("team_id", .text)
                t.column("name", .text).notNull()
                t.column("version", .text)
                t.column("is_sandboxed", .boolean).notNull().defaults(to: false)
            }
            
            // artifact
            try db.create(table: "artifact") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("identity_id", .text).notNull().references("identity", onDelete: .cascade)
                t.column("url", .text).notNull()
                t.column("kind", .text).notNull()
            }
            
            // observation (history is stored as append-only observations)
            try db.create(table: "observation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("identity_id", .text).notNull().references("identity", onDelete: .cascade)
                t.column("observed_at", .datetime).notNull()
                t.column("state", .text).notNull() // e.g. "installed", "removed"
            }
            
            // evidence
            try db.create(table: "evidence") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("identity_id", .text).notNull().references("identity", onDelete: .cascade)
                t.column("url", .text).notNull()
                t.column("tier", .text).notNull()
                t.column("mechanism", .text).notNull()
                t.column("human_sentence", .text).notNull()
            }
            
            // plan
            try db.create(table: "plan") { t in
                t.column("id", .text).primaryKey() // plan UUID
                t.column("hash", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("intent_type", .text).notNull()
                t.column("intent_subject", .text).notNull()
                t.column("requester_kind", .text).notNull()
                t.column("requester_identity", .text).notNull()
                t.column("expected_total_bytes", .integer).notNull()
            }
            
            // plan_step
            try db.create(table: "plan_step") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("plan_id", .text).notNull().references("plan", onDelete: .cascade)
                t.column("step_index", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("target", .text).notNull()
                t.column("tier", .text).notNull()
                t.column("capability", .text).notNull()
            }
            
            // ledger
            try db.create(table: "ledger") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("plan_id", .text).notNull().references("plan")
                t.column("executed_at", .datetime).notNull()
                t.column("recovered_bytes", .integer).notNull()
            }
            
            // journal
            try db.create(table: "journal") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("plan_id", .text).notNull().references("plan")
                t.column("started_at", .datetime).notNull()
                t.column("status", .text).notNull() // e.g. "pending", "completed", "crashed"
            }
        }
        
        try migrator.migrate(dbPool)
    }
}
