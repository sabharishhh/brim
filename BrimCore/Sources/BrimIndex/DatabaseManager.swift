import Foundation
import Darwin
import GRDB

public struct DatabaseManager: Sendable {
    public let dbPool: DatabasePool
    
    /// Initializes the database pool at the given URL, rebuilding if corrupt.
    public init(databaseURL: URL) throws {
        let configuration = Configuration()
        // WAL mode is default for DatabasePool, but we can be explicit.
        
        var pool: DatabasePool?
        do {
            pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
            // Attempt to read from it to ensure it's not corrupt
            try pool?.read { db in
                _ = try String.fetchOne(db, sql: "PRAGMA schema_version")
            }
        } catch let error as DatabaseError where error.resultCode.rawValue == 11 || error.resultCode.rawValue == 26 {
            // ONLY nuke if explicitly corrupt (11) or not a DB (26).
            unlink(databaseURL.path)
            unlink(databaseURL.path + "-wal")
            unlink(databaseURL.path + "-shm")
            
            pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        } // Any other error (like SQLITE_BUSY, locked, permission denied) throws up to caller to prevent data loss
        
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
    public func checkIntegrity() throws {
        try dbPool.read { db in
            let row = try Row.fetchOne(db, sql: "PRAGMA integrity_check")
            if let result = row?[0] as? String, result.lowercased() != "ok" {
                throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "Integrity check failed: \(result)")
            }
        }
    }

}
