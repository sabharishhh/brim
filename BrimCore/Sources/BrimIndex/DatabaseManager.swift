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

        // v2 widens the append-only observation table so one snapshot can be
        // subtracted from the one before. A separate migration rather than an edit
        // to v1, so an existing database comes forward.
        migrator.registerMigration("v2-install-snapshots") { db in
            try db.alter(table: "observation") { t in
                // Which listing this row belongs to; every row of one scan shares it, so
                // "the previous scan" can be selected.
                t.add(column: "scan_id", .text)
                t.add(column: "version", .text)
                t.add(column: "bundle_path", .text)
                t.add(column: "size_bytes", .integer)
                /// When the bundle arrived and when it was last opened, both from Spotlight
                /// and both optional. Together they tell migrated software from software
                /// someone uses.
                t.add(column: "added_at", .datetime)
                t.add(column: "last_used_at", .datetime)
            }
            try db.create(
                index: "observation_by_scan", on: "observation",
                columns: ["scan_id", "identity_id"]
            )
            try db.create(
                index: "observation_by_time", on: "observation",
                columns: ["observed_at"]
            )
        }

        // Every name an app answered to, since once the bundle is gone these are
        // all Brim has to recognise its folders.
        migrator.registerMigration("v3-recorded-names") { database in
            try database.alter(table: "identity") { table in
                table.add(column: "names", .text)
            }
        }

        try migrator.migrate(dbPool)
    }

    /// Which migrations this database has had, so a test can prove an old
    /// database comes forward rather than being rebuilt.
    public func appliedMigrations() throws -> Set<String> {
        try dbPool.read { db in
            try Set(String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        }
    }
}
