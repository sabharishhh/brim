import XCTest
import BrimCore
@testable import BrimScan

/// How each application gets its next version, read from the disk.
///
/// The Updates section listed background updater agents and nothing else,
/// which answers "who is checking in the background" and says nothing
/// about the application in front of you. The useful question is whether
/// each application has any route to a new version at all, and the
/// interesting answer is the applications that do not.
final class UpdateSourceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("updates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func makeApp(
        _ name: String, bundleID: String = "com.example.app",
        info: [String: Any] = [:], appStoreReceipt: Bool = false
    ) throws -> InstalledApplication {
        let bundle = directory.appendingPathComponent("\(name).app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        var plist = info
        plist["CFBundleIdentifier"] = bundleID
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        if appStoreReceipt {
            let receiptFolder = contents.appendingPathComponent("_MASReceipt")
            try FileManager.default.createDirectory(
                at: receiptFolder, withIntermediateDirectories: true
            )
            try Data("receipt".utf8).write(to: receiptFolder.appendingPathComponent("receipt"))
        }

        return InstalledApplication(
            identity: Identity(bundleID: bundleID, name: name),
            url: bundle, bundleSizeBytes: 1_000, isSystemProtected: false
        )
    }

    // MARK: - Reading the sources

    func testASparkleFeedIsFound() throws {
        // Real shape, from IINA on this Mac.
        let app = try makeApp(
            "IINA", info: ["SUFeedURL": "https://www.iina.io/appcast.xml"]
        )
        let sources = UpdateSourceScanner().sources(for: app, casks: [])

        XCTAssertEqual(sources, [.sparkle(feed: "https://www.iina.io/appcast.xml")])
        XCTAssertTrue(
            sources[0].sentence.contains("www.iina.io"),
            "The host is the part that says who is being trusted: \(sources[0].sentence)"
        )
        XCTAssertFalse(
            sources[0].sentence.contains("appcast.xml"),
            "A whole feed URL in a row is noise"
        )
    }

    func testAnAppStoreReceiptIsFound() throws {
        let app = try makeApp("Store App", appStoreReceipt: true)
        XCTAssertEqual(UpdateSourceScanner().sources(for: app, casks: []), [.appStore])
    }

    func testAnApplicationCanHaveSeveralRoutes() throws {
        let app = try makeApp(
            "Both", info: ["SUFeedURL": "https://example.com/feed.xml"], appStoreReceipt: true
        )
        let sources = UpdateSourceScanner().sources(for: app, casks: [])

        XCTAssertEqual(sources.count, 2)
        XCTAssertTrue(sources.contains(.appStore))
    }

    func testAnApplicationWithNoRouteIsTheFinding() throws {
        let app = try makeApp("Stranded")
        let coverage = UpdateCoverage(
            application: app, sources: UpdateSourceScanner().sources(for: app, casks: [])
        )

        XCTAssertTrue(coverage.hasNoWayToUpdate)
        XCTAssertTrue(
            coverage.sentence.contains("Nothing updates this"),
            "The row has to say the consequence: \(coverage.sentence)"
        )
    }

    func testMacOSUpdatesItsOwnApplications() {
        // A protected application is not a finding. Saying "nothing
        // updates Safari" would be both wrong and unactionable.
        let safari = InstalledApplication(
            identity: Identity(bundleID: "com.apple.Safari", name: "Safari"),
            url: URL(fileURLWithPath: "/Applications/Safari.app"),
            bundleSizeBytes: 1, isSystemProtected: true
        )
        let coverage = UpdateCoverage(application: safari, sources: [])
        XCTAssertFalse(coverage.hasNoWayToUpdate)
        XCTAssertTrue(coverage.sentence.contains("macOS updates this"))
    }

    // MARK: - Homebrew

    func testACaskIsMatchedAcrossNamingStyles() throws {
        // Homebrew names a cask after the software, not the bundle:
        // boringNotch.app comes from boring-notch. Both real, from this
        // Mac's Caskroom.
        let app = try makeApp("boringNotch", bundleID: "com.theboredteam.boringnotch")
        let sources = UpdateSourceScanner().sources(for: app, casks: ["boring-notch", "warp"])

        XCTAssertEqual(sources, [.homebrewCask(name: "boring-notch")])
    }

    func testASimilarNameIsNotACask() throws {
        // A loose match would tell somebody to run brew uninstall on a
        // cask that installed something else.
        let app = try makeApp("Notch", bundleID: "com.example.notch")
        XCTAssertTrue(
            UpdateSourceScanner().sources(for: app, casks: ["boring-notch"]).isEmpty
        )
    }

    func testNormalisationIgnoresPunctuationAndCase() {
        XCTAssertEqual(
            UpdateSourceScanner.normalise("Visual Studio Code"),
            UpdateSourceScanner.normalise("visual-studio-code")
        )
        XCTAssertEqual(
            UpdateSourceScanner.normalise("boringNotch"),
            UpdateSourceScanner.normalise("boring-notch")
        )
        XCTAssertNotEqual(
            UpdateSourceScanner.normalise("notch"),
            UpdateSourceScanner.normalise("boring-notch")
        )
    }

    func testHomebrewManagedSoftwareIsNamedForDelegation() throws {
        let app = try makeApp("Warp", bundleID: "dev.warp.Warp-Stable")
        let coverage = UpdateCoverage(
            application: app,
            sources: UpdateSourceScanner().sources(for: app, casks: ["warp"])
        )
        XCTAssertEqual(
            coverage.homebrewCask, "warp",
            "Deleting the files underneath leaves Homebrew believing it is still installed"
        )
    }

    // MARK: - The acceptance criterion

    /// T-5.8: a test asserts no update check occurs without a user action.
    ///
    /// Read from the source rather than exercised, because the failure
    /// being guarded against is somebody adding a convenience later: one
    /// feed fetch during a scan, and a list somebody opened to audit
    /// their Mac has quietly told four vendors they are still running.
    func testNothingInTheScannerReachesTheNetwork() throws {
        let scanner = Self.repositoryRoot()
            .appendingPathComponent("BrimCore/Sources/BrimScan/UpdateSourceScanner.swift")
        let text = try String(contentsOf: scanner, encoding: .utf8)

        for forbidden in [
            "URLSession", "dataTask", "NSURLConnection", "Network.", "CFNetwork",
            "contentsOf: URL(string", "http://", "https://",
        ] {
            XCTAssertFalse(
                text.contains(forbidden),
                "The update scanner reaches the network with \(forbidden). Everything it "
                + "reports is a file, and a section that phones home while you are reading "
                + "it cannot be audited."
            )
        }
    }

    func testTheReportRendersTheSameWithNoNetwork() throws {
        // There is nothing to switch off: the scan is files. This asserts
        // the shape of that claim, which is that a report built from
        // local reads alone is complete rather than degraded.
        let stranded = try makeApp("Stranded")
        let sparkle = try makeApp(
            "Feeder", bundleID: "com.example.feeder",
            info: ["SUFeedURL": "https://example.com/appcast.xml"]
        )
        let scanner = UpdateSourceScanner()
        let report = UpdateReport(
            coverage: [
                UpdateCoverage(application: stranded, sources: scanner.sources(for: stranded, casks: [])),
                UpdateCoverage(application: sparkle, sources: scanner.sources(for: sparkle, casks: [])),
            ],
            agents: [], homebrewPresent: false
        )

        XCTAssertEqual(report.withoutAnyUpdateSource.count, 1)

        // Counts, not complaints. "1 application has no way to update
        // itself" states a dead end on the opening screen and hands the
        // reader nothing to do with it; the same fact split into what
        // updates itself and what they update is a short list to keep an
        // eye on.
        XCTAssertEqual(report.summary, "1 update themselves · 1 you update yourself")
        XCTAssertFalse(report.summary.contains("no way"))
    }

    func testTheSummarySaysNothingWhenThereIsNothingToSay() {
        let report = UpdateReport(coverage: [], agents: [], homebrewPresent: true)
        XCTAssertEqual(report.summary, "Nothing installed to check.")
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}
