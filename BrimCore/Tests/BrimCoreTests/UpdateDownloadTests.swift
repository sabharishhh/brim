import BrimCore
@testable import BrimScan
import XCTest

/// Updates apps downloaded to install themselves, and which of them Brim
/// may clear.
///
/// On the Mac this was written on, Antigravity kept the same 181 MB update
/// twice, as `pending/Antigravity.zip` and `update.zip`, both older than
/// the Antigravity installed, and Notion left a download it abandoned in
/// July. VS Code and Claude had held 2.3 GB of updates already installed.
/// None of it appeared anywhere in Brim.
final class UpdateDownloadTests: XCTestCase {
    private var home: URL!
    private var apps: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("upd-\(UUID().uuidString)")
        apps = home.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func put(_ relative: String, modified: Date? = nil) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            try FileManager.default.setAttributes([.modificationDate: modified],
                                                  ofItemAtPath: url.deletingLastPathComponent().path)
        }
    }

    private func app(_ name: String, version: String) throws -> URL {
        let bundle = apps.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        try (["CFBundleShortVersionString": version] as NSDictionary)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    private func scanner(_ known: [String: URL]) -> UpdateDownloadScanner {
        UpdateDownloadScanner(resolve: { known[$0] })
    }

    func testACopyOlderThanTheInstalledAppIsClearedAndAWaitingOneIsLeft() throws {
        let past = Date(timeIntervalSinceNow: -3 * 24 * 60 * 60)
        try put("Library/Caches/com.google.antigravity/pending/Antigravity.zip", modified: past)
        try put("Library/Caches/com.google.antigravity/update.zip", modified: past)
        // Put in place after the download, the way an updater replaces it.
        let antigravity = try app("Antigravity", version: "1.2")

        // Downloaded after the installed copy was put in place.
        let late = try app("Late", version: "1.0")
        try put("Library/Caches/com.example.late/pending/Late.zip", modified: Date(timeIntervalSinceNow: 3600))

        let found = scanner(["com.google.antigravity": antigravity, "com.example.late": late]).scan(home: home)
        let antigravityRows = found.filter { $0.tool == "Antigravity" }
        XCTAssertEqual(antigravityRows.count, 2)
        XCTAssertTrue(antigravityRows.allSatisfy { $0.cost == .rebuilt && $0.isUpdateDownload })
        XCTAssertEqual(found.first { $0.tool == "Late" }?.cost, .configured,
                       "an update the app has not installed yet is its own to use")
    }

    func testSquirrelIsJudgedByTheStagedVersion() throws {
        let installed = try app("Code", version: "1.139.1")
        try put("Library/Caches/com.microsoft.VSCode.ShipIt/update.old/Code.app/Contents/MacOS/Code")
        try (["CFBundleShortVersionString": "1.139.0"] as NSDictionary).write(
            to: home
                .appendingPathComponent(
                    "Library/Caches/com.microsoft.VSCode.ShipIt/update.old/Code.app/Contents/Info.plist"
                )
        )
        try put("Library/Caches/com.microsoft.VSCode.ShipIt/update.new/Code.app/Contents/MacOS/Code")
        try (["CFBundleShortVersionString": "1.140.0"] as NSDictionary).write(
            to: home
                .appendingPathComponent(
                    "Library/Caches/com.microsoft.VSCode.ShipIt/update.new/Code.app/Contents/Info.plist"
                )
        )
        // The log and state beside them are ShipIt's own, not a download.
        try put("Library/Caches/com.microsoft.VSCode.ShipIt/ShipItState.plist")

        let found = scanner(["com.microsoft.VSCode": installed]).scan(home: home)
        let costs = Dictionary(uniqueKeysWithValues: found.map { ($0.url.lastPathComponent, $0.cost) })
        XCTAssertEqual(costs, ["update.old": .rebuilt, "update.new": .configured])
    }

    func testAnUpdateForAnAppThatIsGoneIsLeftToRemovedApps() throws {
        try put("Library/Application Support/Caches/notion-updater/pending/temp-Notion-arm64-7.26.0.zip")
        XCTAssertTrue(scanner([:]).scan(home: home).isEmpty)
    }

    func testADownloadThatNeverFinishedIsClearedAfterAWeek() throws {
        let notion = try app("Notion", version: "7.25.0")
        let past = Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
        try put(
            "Library/Application Support/Caches/notion-updater/pending/temp-Notion-arm64-7.26.0.zip",
            modified: past
        )

        let found = scanner(["notion": notion]).scan(home: home)
        XCTAssertEqual(found.map(\.cost), [.rebuilt])
        XCTAssertTrue(found.first?.explanation.contains("never finished") == true)
    }
}
