import BrimCore
@testable import BrimIndex
import GRDB
import XCTest

/// History, kept by writing snapshots and subtracting them.
final class InstallHistoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeIndex(named name: String = "brim.sqlite") throws -> Index {
        try Index(dbManager: DatabaseManager(
            databaseURL: directory.appendingPathComponent(name)
        ))
    }

    private func app(
        _ bundleID: String, _ name: String,
        version: String = "1.0", size: Int64 = 1000
    ) -> InstallObservation {
        InstallObservation(
            bundleID: bundleID, name: name, version: version,
            bundlePath: "/Applications/\(name).app", sizeBytes: size
        )
    }

    func testTheFirstLookHasNothingToCompareAgainst() async throws {
        // The first look has nothing to compare with, so nothing is "new".
        let index = try makeIndex()
        _ = try await index.recordInstalled([app("com.a", "Alpha")])

        let changes = try await index.changesSinceLastScan()
        XCTAssertTrue(changes.isEmpty)
        let count = try await index.snapshotCount()
        XCTAssertEqual(count, 1, "One snapshot is not nothing changed, it is nothing to compare")
    }

    func testOnlyWhatArrivedAfterTheFirstLookHasAnArrivalDate() async throws {
        // Everything is first seen at the first look, so that is not an install
        // date.
        let index = try makeIndex()
        let firstLook = Date(timeIntervalSince1970: 1_000_000)
        let later = firstLook.addingTimeInterval(24 * 60 * 60)
        _ = try await index.recordInstalled([app("com.a", "Alpha")], at: firstLook)
        _ = try await index.recordInstalled([app("com.a", "Alpha"), app("com.b", "Beta")], at: later)

        let appeared = try await index.appearances()
        XCTAssertEqual(appeared, ["com.b": later])
    }

    /// First appearing is not arriving: an app newly included in the list was
    /// already on disk. The window says when Brim last looked before, so the
    /// bundle's own date can be checked against it.
    func testAnAppearanceKnowsWhenBrimLastLookedBeforeIt() async throws {
        let index = try makeIndex()
        let first = Date(timeIntervalSince1970: 1_000_000)
        let second = first.addingTimeInterval(3600)
        let third = second.addingTimeInterval(3600)
        _ = try await index.recordInstalled([app("com.a", "Alpha")], at: first)
        _ = try await index.recordInstalled([app("com.a", "Alpha")], at: second)
        _ = try await index.recordInstalled([app("com.a", "Alpha"), app("com.b", "Beta")], at: third)

        let windows = try await index.appearanceWindows()
        XCTAssertEqual(windows, ["com.b": AppearanceWindow(seen: third, previousLook: second)])
    }

    func testSomethingInstalledBetweenLooksIsFound() async throws {
        let index = try makeIndex()
        _ = try await index.recordInstalled([app("com.a", "Alpha")])
        _ = try await index.recordInstalled([app("com.a", "Alpha"), app("com.b", "Beta")])

        let changes = try await index.changesSinceLastScan()
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].kind, .appeared)
        XCTAssertEqual(changes[0].bundleID, "com.b")
        XCTAssertTrue(changes[0].sentence.contains("Beta was installed"))
    }

    func testSomethingRemovedBetweenLooksIsFound() async throws {
        let index = try makeIndex()
        _ = try await index.recordInstalled([app("com.a", "Alpha"), app("com.b", "Beta")])
        _ = try await index.recordInstalled([app("com.a", "Alpha")])

        let changes = try await index.changesSinceLastScan()
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].kind, .disappeared)
        XCTAssertTrue(changes[0].sentence.contains("was removed"))
    }

    func testAnUpdateIsReportedWithBothVersions() async throws {
        let index = try makeIndex()
        _ = try await index.recordInstalled([app("com.a", "Alpha", version: "1.0")])
        _ = try await index.recordInstalled([app("com.a", "Alpha", version: "2.0")])

        let changes = try await index.changesSinceLastScan()
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].kind, .updated(from: "1.0", to: "2.0"))
        XCTAssertTrue(changes[0].sentence.contains("1.0 to 2.0"))
    }

    func testGrowthWithoutAnUpdateIsReported() async throws {
        // An app that did not update and grew anyway is a cache nobody is clearing.
        let index = try makeIndex()
        _ = try await index.recordInstalled([app("com.a", "Alpha", size: 100_000_000)])
        _ = try await index.recordInstalled([app("com.a", "Alpha", size: 600_000_000)])

        let changes = try await index.changesSinceLastScan()
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].kind, .grew(by: 500_000_000))
    }

    func testAnUpdateThatGrewIsOneEventAndNotTwo() async throws {
        let index = try makeIndex()
        _ = try await index.recordInstalled([app("com.a", "Alpha", version: "1.0", size: 1000)])
        _ = try await index.recordInstalled([
            app("com.a", "Alpha", version: "2.0", size: 900_000_000)
        ])

        let changes = try await index.changesSinceLastScan()
        XCTAssertEqual(changes.count, 1, "An update that grew is an update")
        XCTAssertEqual(changes[0].kind, .updated(from: "1.0", to: "2.0"))
    }

    func testOrdinaryDriftIsNotReported() async throws {
        // Small size changes would bury the one that moved a lot.
        let index = try makeIndex()
        _ = try await index.recordInstalled([app("com.a", "Alpha", size: 100_000_000)])
        _ = try await index.recordInstalled([app("com.a", "Alpha", size: 101_000_000)])

        let changes = try await index.changesSinceLastScan()
        XCTAssertTrue(changes.isEmpty)
    }

    func testNothingIsEverOverwritten() async throws {
        // An overwritten row cannot be subtracted from.
        let index = try makeIndex()
        for _ in 0 ..< 5 {
            _ = try await index.recordInstalled([app("com.a", "Alpha")])
        }

        let count = try await index.snapshotCount()
        XCTAssertEqual(count, 5, "Snapshots were collapsed, so history was lost")
    }

    func testTheComparisonIsAgainstTheLastLookAndNotTheFirst() async throws {
        let index = try makeIndex()
        _ = try await index.recordInstalled([app("com.a", "Alpha")])
        _ = try await index.recordInstalled([app("com.a", "Alpha"), app("com.b", "Beta")])
        _ = try await index.recordInstalled([app("com.a", "Alpha"), app("com.b", "Beta"), app("com.c", "Gamma")])

        let changes = try await index.changesSinceLastScan()
        XCTAssertEqual(changes.map(\.bundleID), ["com.c"], "Beta appeared two looks ago, not since the last one")
    }

    /// Every launch takes a snapshot, so the last change stands until there is
    /// a newer one.
    func testARelaunchDoesNotEmptyTheLastChange() async throws {
        let index = try makeIndex()
        _ = try await index.recordInstalled([app("com.a", "Alpha")])
        _ = try await index.recordInstalled([app("com.a", "Alpha"), app("com.b", "Beta")])
        _ = try await index.recordInstalled([app("com.a", "Alpha"), app("com.b", "Beta")])
        _ = try await index.recordInstalled([app("com.a", "Alpha"), app("com.b", "Beta")])

        let changes = try await index.changesSinceLastScan()
        XCTAssertEqual(changes.map(\.bundleID), ["com.b"])
        XCTAssertEqual(changes.first?.kind, .appeared)
    }

    /// An existing v1 database migrates rather than being rebuilt.
    func testAV1DatabaseComesForwardRatherThanBeingRebuilt() throws {
        let url = directory.appendingPathComponent("legacy.sqlite")

        // A database as v1 left it, without the columns a snapshot needs.
        let pool = try DatabasePool(path: url.path)
        try pool.write { db in
            try db.execute(sql: """
            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
            """)
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v1')")
            try db.execute(sql: """
            CREATE TABLE identity (
                id TEXT PRIMARY KEY, bundle_id TEXT, team_id TEXT,
                name TEXT NOT NULL, version TEXT,
                is_sandboxed BOOLEAN NOT NULL DEFAULT 0
            );
            """)
            try db.execute(sql: """
            CREATE TABLE observation (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                identity_id TEXT NOT NULL REFERENCES identity(id) ON DELETE CASCADE,
                observed_at DATETIME NOT NULL, state TEXT NOT NULL
            );
            """)
            try db.execute(
                sql: "INSERT INTO identity (id, bundle_id, name) VALUES ('com.old', 'com.old', 'Older')"
            )
            try db.execute(sql: """
            INSERT INTO observation (identity_id, observed_at, state)
            VALUES ('com.old', '2020-01-01 00:00:00', 'installed')
            """)
        }
        try pool.close()

        let manager = try DatabaseManager(databaseURL: url)

        XCTAssertTrue(try manager.appliedMigrations().contains("v2-install-snapshots"))
        let survived = try manager.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM observation") ?? 0
        }
        XCTAssertEqual(survived, 1, "The old history was thrown away by the migration")
    }

    func testANewDatabaseGetsEveryMigration() throws {
        let manager = try DatabaseManager(
            databaseURL: directory.appendingPathComponent("fresh.sqlite")
        )
        let applied = try manager.appliedMigrations()
        XCTAssertTrue(applied.contains("v1"))
        XCTAssertTrue(applied.contains("v2-install-snapshots"))
    }

    /// An app an earlier snapshot saw and the latest did not is removed as of
    /// the last time it was seen.
    func testAnAppAnEarlierSnapshotSawIsRemovedAsOfTheLastTimeItWasSeen() async throws {
        let index = try makeIndex()
        let first = Date(timeIntervalSince1970: 1_000_000)
        let second = first.addingTimeInterval(86400)
        _ = try await index.recordInstalled([app("com.a", "Alpha"), app("com.b", "Beta"),
                                             app("com.apple.x", "Apple")], at: first)
        _ = try await index.recordInstalled([app("com.a", "Alpha"), app("com.b", "Beta")], at: second)
        _ = try await index.recordInstalled([app("com.a", "Alpha")], at: second.addingTimeInterval(86400))

        let removed = try await index.removedApplications()
        XCTAssertEqual(Set(removed.keys), ["com.b"], "macOS's own are left out")
        XCTAssertEqual(removed["com.b"], second)
    }

    /// Only the last place a removed app was seen: one that moved away was not
    /// replaced by whatever sits there now.
    func testTheLastPlaceARemovedAppWasSeenIsRecorded() async throws {
        let index = try makeIndex()
        let first = Date(timeIntervalSince1970: 1_000_000)
        _ = try await index.recordInstalled([app("com.b", "Beta")], at: first)
        _ = try await index.recordInstalled([InstallObservation(bundleID: "com.b", name: "Beta", version: "1.0",
                                                                bundlePath: "/Users/x/Applications/Beta.app",
                                                                sizeBytes: 1)],
                                            at: first.addingTimeInterval(60))
        let paths = try await index.lastBundlePaths(of: ["com.b", "com.none"])
        XCTAssertEqual(paths, ["com.b": "/Users/x/Applications/Beta.app"])
    }
}
