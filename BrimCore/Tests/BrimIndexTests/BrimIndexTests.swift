import XCTest
import GRDB
import BrimCore
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
    
    func testIndexActorConcurrency() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(atPath: tempURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: tempURL.path + "-shm")
        }
        
        let dbManager = try DatabaseManager(databaseURL: tempURL)
        let index = Index(dbManager: dbManager)
        
        struct DummyApp: AppArtifact {
            var bundleID: String
            var name: String
            var evidence: [Evidence]
        }
        
        let apps: [any AppArtifact] = (1...100).map { i in
            DummyApp(
                bundleID: "com.brim.dummy\(i)",
                name: "Dummy App \(i)",
                evidence: [
                    Evidence(url: URL(fileURLWithPath: "/tmp/dummy\(i)"), tier: .S, mechanism: "test", humanSentence: "test")
                ]
            )
        }
        
        // Spawn concurrent readers while writing
        async let writeTask: () = try index.recordScan(apps: apps)
        
        async let readTask: () = withThrowingTaskGroup(of: Void.self) { group in
            for _ in 1...50 {
                group.addTask {
                    let name = try await index.fetchIdentity(bundleID: "com.brim.dummy50")
                    // It might be nil if the write hasn't finished, or the name if it has. Both are valid.
                    // The key is that it doesn't crash or throw a locking error.
                    _ = name
                }
            }
            try await group.waitForAll()
        }
        
        _ = try await (writeTask, readTask)
        
        // Post condition
        let name = try await index.fetchIdentity(bundleID: "com.brim.dummy50")
        XCTAssertEqual(name, "Dummy App 50")
    }
}
