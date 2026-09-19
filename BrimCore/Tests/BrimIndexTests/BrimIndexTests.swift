import XCTest
import GRDB
@testable import BrimIndex

final class DatabaseManagerTests: XCTestCase {
    
    func testMigrationAndRebuildOnCorruption() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(atPath: tempURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: tempURL.path + "-shm")
        }
        
        // 1. Create a fresh database and migrate
        let manager1 = try DatabaseManager(databaseURL: tempURL)
        
        // Verify tables exist
        try manager1.dbPool.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            XCTAssertTrue(tables.contains("identity"))
            XCTAssertTrue(tables.contains("plan"))
            XCTAssertTrue(tables.contains("artifact"))
        }
        
        // 2. Deliberately corrupt the database file
        let junk = Data(repeating: 0xff, count: 1024)
        try junk.write(to: tempURL)
        
        // 3. Open again, it should detect corruption and rebuild seamlessly
        let manager2 = try DatabaseManager(databaseURL: tempURL)
        
        // Verify it was rebuilt and migrated
        try manager2.dbPool.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            XCTAssertTrue(tables.contains("ledger"))
            XCTAssertTrue(tables.contains("evidence"))
        }
    }
}
