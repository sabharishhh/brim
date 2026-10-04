import XCTest
import BrimCore
@testable import BrimScan

/// Which Homebrew cask an application came from, read from the disk.
///
/// A wrong answer here sends an update to Homebrew for something it did
/// not install, or leaves Homebrew believing a removed app is still there.
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

    // MARK: - Homebrew

    func testNamesAloneDoNotEstablishInstallationOwnership() throws {
        let app = try makeApp("boringNotch", bundleID: "com.theboredteam.boringnotch")
        XCTAssertNil(UpdateSourceScanner.matchingCask(for: app, among: ["boring-notch", "warp"]))
    }

    func testASimilarNameIsNotACask() throws {
        // A loose match would tell somebody to run brew uninstall on a
        // cask that installed something else.
        let app = try makeApp("Notch", bundleID: "com.example.notch")
        XCTAssertNil(UpdateSourceScanner.matchingCask(for: app, among: ["boring-notch"]))
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

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}
