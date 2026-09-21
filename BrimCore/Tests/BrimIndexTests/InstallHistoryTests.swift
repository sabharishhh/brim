import XCTest
import BrimCore
import GRDB
@testable import BrimIndex

/// History, kept by writing snapshots and subtracting them.
///
/// The index compiled, had a schema with an `observation` table, and was
/// imported by nothing that mattered: `BrimService` never opened it. So
/// there was no history, and everything resting on one, a "what changed"
/// view and migration hygiene both, could not be built. The schema
/// existing is not the feature.
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
        Index(dbManager: try DatabaseManager(
            databaseURL: directory.appendingPathComponent(name)
        ))
    }

    private func app(
        _ bundleID: String, _ name: String,
        version: String = "1.0", size: Int64 = 1_000
    ) -> InstallObservation {
        InstallObservation(
            bundleID: bundleID, name: name, version: version,
            bundlePath: "/Applications/\(name).app", sizeBytes: size
        )
    }

    func testTheFirstLookHasNothingToCompareAgainst() async throws {
        // Inventing a list of "new" applications the first time somebody
        // opens Brim would make every later list untrustworthy.
        let index = try makeIndex()
        _ = try await index.recordInstalled([app("com.a", "Alpha")])

        let changes = try await index.changesSinceLastScan()
        XCTAssertTrue(changes.isEmpty)
        let count = try await index.snapshotCount()
        XCTAssertEqual(count, 1, "One snapshot is not nothing changed, it is nothing to compare")
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
        XCTAssertTrue(
            changes[0].sentence.contains("Leftovers"),
            "A removal is the moment to say where what it left behind is"
        )
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
        // The interesting one: an application that did not update and got
        // half a gigabyte bigger anyway is a cache nobody is clearing.
        let index = try makeIndex()
        _ = try await index.recordInstalled([app("com.a", "Alpha", size: 100_000_000)])
        _ = try await index.recordInstalled([app("com.a", "Alpha", size: 600_000_000)])

        let changes = try await index.changesSinceLastScan()
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].kind, .grew(by: 500_000_000))
    }

    func testAnUpdateThatGrewIsOneEventAndNotTwo() async throws {
        let index = try makeIndex()
        _ = try await index.recordInstalled([app("com.a", "Alpha", version: "1.0", size: 1_000)])
        _ = try await index.recordInstalled([
            app("com.a", "Alpha", version: "2.0", size: 900_000_000)
        ])

        let changes = try await index.changesSinceLastScan()
        XCTAssertEqual(changes.count, 1, "An update that grew is an update")
        XCTAssertEqual(changes[0].kind, .updated(from: "1.0", to: "2.0"))
    }

    func testOrdinaryDriftIsNotReported() async throws {
        // Every application's size moves a little. Reporting that would
        // bury the one that moved a lot.
        let index = try makeIndex()
        _ = try await index.recordInstalled([app("com.a", "Alpha", size: 100_000_000)])
        _ = try await index.recordInstalled([app("com.a", "Alpha", size: 101_000_000)])

        let changes = try await index.changesSinceLastScan()
        XCTAssertTrue(changes.isEmpty)
    }

    func testNothingIsEverOverwritten() async throws {
        // Append-only is not tidiness. A row that is overwritten cannot
        // be subtracted from, which would mean watching for changes with
        // a resident process, which is the thing nobody wants running.
        let index = try makeIndex()
        for _ in 0..<5 {
            _ = try await index.recordInstalled([app("com.a", "Alpha")])
        }

        let count = try await index.snapshotCount()
        XCTAssertEqual(count, 5, "Snapshots were collapsed, so history was lost")
    }

    func testTheComparisonIsAgainstTheLastLookAndNotTheFirst() async throws {
        let index = try makeIndex()
        _ = try await index.recordInstalled([app("com.a", "Alpha")])
        _ = try await index.recordInstalled([app("com.a", "Alpha"), app("com.b", "Beta")])
        _ = try await index.recordInstalled([app("com.a", "Alpha"), app("com.b", "Beta")])

        let changes = try await index.changesSinceLastScan()
        XCTAssertTrue(changes.isEmpty, "Beta appeared two looks ago, not since the last one")
    }

    /// T-1.4's acceptance criterion, and the one nobody finds out about
    /// until somebody's history disappears.
    func testAV1DatabaseComesForwardRatherThanBeingRebuilt() throws {
        let url = directory.appendingPathComponent("legacy.sqlite")

        // A database as v1 left it: the observation table without any of
        // the columns a snapshot needs.
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
}

/// Software that came across from another Mac and never ran here.
final class MigrationHygieneTests: XCTestCase {

    private let systemInstalled = Date(timeIntervalSince1970: 1_000_000)

    private func date(_ offsetDays: Double) -> Date {
        systemInstalled.addingTimeInterval(offsetDays * 86_400)
    }

    func testUsedSinceItArrivedIsOrdinarySoftware() {
        let verdict = MigrationHygiene.judge(
            addedAt: date(10), lastUsedAt: date(20), systemInstalledAt: systemInstalled
        )
        XCTAssertEqual(verdict, .inUse)
        XCTAssertFalse(verdict.isWorthReviewing)
    }

    func testLastUsedBeforeItArrivedIsTheMigrationSignature() {
        // The sharp signal, and the one the specification does not name.
        // A last-used date earlier than the date the bundle arrived can
        // only happen when the usage record travelled with it. Observed
        // on this Mac: IINA arrived on 14 September, last opened 7 August.
        let arrived = date(10)
        let usedElsewhere = date(-30)
        let verdict = MigrationHygiene.judge(
            addedAt: arrived, lastUsedAt: usedElsewhere, systemInstalledAt: systemInstalled
        )

        XCTAssertEqual(verdict, .cameAcrossAndNeverRan(lastUsedElsewhere: usedElsewhere))
        XCTAssertTrue(verdict.isWorthReviewing)
        XCTAssertTrue(verdict.sentence.contains("never run on this Mac"))
    }

    func testADayOfSlackAbsorbsSpotlightWritingThemSeparately() {
        // Both dates are written by Spotlight and not written together,
        // so a few minutes either way must not read as a migration.
        let arrived = date(10)
        let verdict = MigrationHygiene.judge(
            addedAt: arrived,
            lastUsedAt: arrived.addingTimeInterval(-600),
            systemInstalledAt: systemInstalled
        )
        XCTAssertEqual(verdict, .inUse)
    }

    func testNeverOpenedAtAllIsWorthSaying() {
        let verdict = MigrationHygiene.judge(
            addedAt: date(10), lastUsedAt: nil, systemInstalledAt: systemInstalled
        )
        XCTAssertEqual(verdict, .neverOpened)
        XCTAssertTrue(verdict.isWorthReviewing)
    }

    func testSomethingOlderThanTheSystemCameFromSomewhereElse() {
        let verdict = MigrationHygiene.judge(
            addedAt: date(-100), lastUsedAt: date(-99), systemInstalledAt: systemInstalled
        )
        XCTAssertEqual(verdict, .predatesThisSystem)
    }

    func testNotEnoughToSayIsNotAnAccusation() {
        // Spotlight can be switched off for a volume, and a freshly
        // copied bundle may not be indexed yet. Neither is evidence of
        // anything, and a row claiming otherwise would be a guess wearing
        // a fact's clothes.
        let verdict = MigrationHygiene.judge(
            addedAt: nil, lastUsedAt: date(5), systemInstalledAt: systemInstalled
        )
        guard case .unknown = verdict else {
            return XCTFail("Expected unknown, got \(verdict)")
        }
        XCTAssertFalse(verdict.isWorthReviewing)
    }

    func testTheHistorySummarySaysWhichSituationItIs() {
        let first = InstallHistory(changes: [], snapshots: 1, migrated: [])
        XCTAssertTrue(first.summary.contains("first time"))

        let quiet = InstallHistory(changes: [], snapshots: 2, migrated: [])
        XCTAssertTrue(quiet.summary.contains("Nothing has been installed"))

        let busy = InstallHistory(
            changes: [
                InstallChange(
                    kind: .appeared, bundleID: "com.a", name: "Alpha",
                    since: Date(), until: Date()
                )
            ],
            snapshots: 2, migrated: []
        )
        XCTAssertTrue(busy.summary.contains("1 thing has changed"))
    }
}
