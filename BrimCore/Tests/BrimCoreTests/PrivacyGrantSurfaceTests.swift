@testable import BrimCore
@testable import BrimScan
import Foundation
import SQLite3
import XCTest

/// A privacy permission outlives the program it was given to.
///
/// On 6 October Full Disk Access still listed
/// `/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper` long
/// after Microsoft AutoUpdate was removed, and nothing in Brim said so.
final class PrivacyGrantSurfaceTests: XCTestCase {
    private var folder: URL!
    private var root: FileSystemRoot!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-\(UUID().uuidString)")
        root = FileSystemRoot(rootURL: folder, userName: "tester")
        let tcc = folder.appendingPathComponent("Library/Application Support/com.apple.TCC")
        try FileManager.default.createDirectory(at: tcc, withIntermediateDirectories: true)
        let present = folder.appendingPathComponent("usr/local/bin/tool")
        let bin = present.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: present.path, contents: Data())
        let helper = "/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper"
        try makeDatabase(at: tcc.appendingPathComponent("TCC.db"), rows: [
            .init(service: "kTCCServiceSystemPolicyAllFiles", client: helper, isPath: true),
            .init(service: "kTCCServiceAccessibility", client: helper, isPath: true),
            .init(service: "kTCCServiceSystemPolicyAllFiles", client: "/usr/local/bin/tool", isPath: true),
            .init(service: "kTCCServiceSystemPolicyAllFiles", client: "com.binance.BinanceDesktop", isPath: false),
            // Switched off, for a helper that is gone: grants nothing, and
            // Settings does not list it.
            .init(service: "kTCCServiceSystemPolicyAllFiles", client: "/Library/PrivilegedHelperTools/gone.off",
                  isPath: true, isAllowed: false)
        ])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testAGrantToAProgramThatIsGoneIsListedOnceWithItsPanes() async throws {
        let found = await PrivacyGrantSurface().registrations(in: root)
        XCTAssertEqual(found.map(\.label), ["com.microsoft.autoupdate.helper"],
                       "The present tool is not a leftover, and a bundle identifier cannot be removed from Settings")
        let grant = try XCTUnwrap(found.first)
        XCTAssertTrue(grant.isStale)
        XCTAssertFalse(grant.isActionable, "Brim reads the privacy database and never edits it")
        XCTAssertEqual(grant.evidence,
                       "Accessibility and Full Disk Access still allows this program, but it is no longer on this Mac.")
    }

    func testAnUnreadableDatabaseIsAGapNotAnEmptyList() async throws {
        let database = folder.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        try Data("not a database".utf8).write(to: database)
        let coverage = await PrivacyGrantSurface().coverage(in: root)
        XCTAssertFalse(coverage.available)
    }

    private func makeDatabase(at url: URL, rows: [PrivacyGrantSurface.Row]) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        sqlite3_exec(handle, "CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER)",
                     nil, nil, nil)
        for row in rows {
            let values = "'\(row.service)', '\(row.client)', \(row.isPath ? 1 : 0), \(row.isAllowed ? 2 : 0)"
            let sql = "INSERT INTO access VALUES (\(values))"
            sqlite3_exec(handle, sql, nil, nil, nil)
        }
    }
}
