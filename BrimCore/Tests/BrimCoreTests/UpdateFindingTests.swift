import XCTest
@testable import BrimCore
@testable import BrimScan

/// Finding updates, held to what the first real check on this Mac showed.
///
/// The old checker compared Sparkle's marketing strings with a numeric
/// string compare and knew nothing else, so it could offer a version this
/// Mac cannot run or a beta nobody subscribed to. And every Electron
/// application that sets its feed in code went unchecked.
final class UpdateFindingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("updates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private let sequoia = UpdatePlatform(
        system: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0), isAppleSilicon: true)

    // MARK: - Versions

    func testVersionsOrderAsReleasesDo() {
        XCTAssertTrue(VersionOrder.isNewer("1.10", than: "1.9"))
        XCTAssertEqual(VersionOrder.compare("1.2", "1.2.0"), .orderedSame)
        XCTAssertTrue(VersionOrder.isNewer("1.2.1", than: "1.2"))
        XCTAssertTrue(VersionOrder.isNewer("1.2", than: "1.2b1"), "a pre-release comes before its release")
        XCTAssertEqual(VersionOrder.compare("v2.0", "2.0"), .orderedSame)
        XCTAssertFalse(VersionOrder.isNewer("126.8.18", than: "126.9.10"))
    }

    // MARK: - Sparkle

    private let appcast = """
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>App</title>
    <description>Channel notes</description>
    <item><title>3.0</title><sparkle:version>300</sparkle:version><sparkle:shortVersionString>3.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
      <enclosure url="https://example.com/3.0.zip" length="10" sparkle:edSignature="sig3"/></item>
    <item><title>2.9 beta</title><sparkle:version>290</sparkle:version><sparkle:shortVersionString>2.9</sparkle:shortVersionString>
      <sparkle:channel>beta</sparkle:channel><enclosure url="https://example.com/2.9.zip" length="10"/></item>
    <item><title>2.1</title><sparkle:version>210</sparkle:version><sparkle:shortVersionString>2.1</sparkle:shortVersionString>
      <description><![CDATA[<p>Faster.</p>]]></description>
      <sparkle:deltas><enclosure url="https://example.com/delta.delta" sparkle:version="210" sparkle:deltaFrom="200"/></sparkle:deltas>
      <enclosure url="https://example.com/2.1.zip" length="1234" sparkle:edSignature="sig21"/></item>
    <item><title>2.0</title><sparkle:version>200</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString>
      <enclosure url="https://example.com/2.0.zip" length="10"/></item>
    </channel></rss>
    """

    /// The newest item is for a macOS that does not exist yet, the next is
    /// a beta: the one to offer is 2.1, with its full download rather than
    /// the delta inside it.
    func testTheAppcastItemIsTheNewestThisMacCanInstall() {
        let best = SparkleAppcast.best(in: SparkleAppcast.items(in: Data(appcast.utf8)), for: sequoia)
        XCTAssertEqual(best?.displayVersion, "2.1")
        XCTAssertEqual(best?.enclosureURL, "https://example.com/2.1.zip")
        XCTAssertEqual(best?.enclosureLength, 1234)
        XCTAssertEqual(best?.edSignature, "sig21")
        XCTAssertEqual(best?.notes, "<p>Faster.</p>")
    }

    /// Sparkle orders by build, which is what `CFBundleVersion` holds.
    func testAppcastItemsAreOrderedByBuild() {
        let feed = """
        <rss xmlns:sparkle="x"><channel>
        <item><sparkle:version>300</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString></item>
        <item><sparkle:version>250</sparkle:version><sparkle:shortVersionString>2.0.1</sparkle:shortVersionString></item>
        </channel></rss>
        """
        XCTAssertEqual(SparkleAppcast.best(in: SparkleAppcast.items(in: Data(feed.utf8)), for: sequoia)?.version, "300")
    }

    // MARK: - Electron

    func testElectronBuilderFeedsAreReadFromTheApplicationsOwnConfiguration() throws {
        let feed = try XCTUnwrap(ElectronFeed.feed(fromConfiguration: """
        owner: webadderall
        repo: Recordly
        provider: github
        tagNamePrefix: v
        """))
        XCTAssertEqual(feed.manifest.absoluteString,
                       "https://github.com/webadderall/Recordly/releases/latest/download/latest-mac.yml")
        let manifest = try XCTUnwrap(ElectronFeed.manifest(from: """
        version: 1.4.0
        files:
        - url: Recordly-x64.zip
          sha512: AAA=
          size: 100
        - url: Recordly-arm64.zip
          sha512: BBB=
          size: 90
        - url: Recordly-arm64.dmg
          sha512: CCC=
        path: Recordly-x64.zip
        releaseDate: '2026-09-08T04:46:30.253Z'
        """))
        XCTAssertEqual(manifest.version, "1.4.0")
        let file = try XCTUnwrap(ElectronFeed.file(in: manifest, for: sequoia))
        XCTAssertEqual(file.url, "Recordly-arm64.zip")
        XCTAssertEqual(file.sha512, "BBB=")
        XCTAssertEqual(feed.files(file.url, manifest.version)?.absoluteString,
                       "https://github.com/webadderall/Recordly/releases/download/v1.4.0/Recordly-arm64.zip")
    }

    // MARK: - Homebrew catalogue

    func testACaskIsMatchedByItsApplicationAndThenByIdentifier() {
        let store = CatalogCask(token: "whatsapp", version: "26.38.22", appNames: ["whatsapp.app"],
                                identifiers: ["net.whatsapp.whatsapp"], url: "https://x", sha256: nil,
                                installsPackage: false, minimumSystem: nil, homepage: nil)
        let other = CatalogCask(token: "whatsapp-legacy", version: "2.0", appNames: ["whatsapp.app"],
                                identifiers: ["desktop.whatsapp"], url: "https://y", sha256: nil,
                                installsPackage: false, minimumSystem: nil, homepage: nil)
        XCTAssertEqual(HomebrewCatalog.match(fileName: "WhatsApp.app", bundleID: "net.whatsapp.WhatsApp",
                                             in: [store, other])?.token, "whatsapp")
        XCTAssertNil(HomebrewCatalog.match(fileName: "WhatsApp.app", bundleID: "com.unknown", in: [store, other]))
    }

    /// WhatsApp here came from the App Store, and the catalogue's newer
    /// build is the direct download: the receipt decides the source. Figma
    /// was ahead of the catalogue, which is not an update.
    func testTheReceiptDecidesTheSourceAndACatalogueBehindIsNotAnUpdate() async throws {
        let store = try app("WhatsApp", "net.whatsapp.WhatsApp", "26.37.76", receipt: true)
        let figma = try app("Figma", "com.figma.Desktop", "126.9.10")
        let code = try app("Visual Studio Code", "com.microsoft.VSCode", "1.138.0")
        let catalogue = folder.appendingPathComponent("catalogue")
        try FileManager.default.createDirectory(at: catalogue, withIntermediateDirectories: true)
        try Data("""
        [{"token":"whatsapp","version":"26.38.22","url":"https://w","sha256":"no_check",
          "artifacts":[{"app":["WhatsApp.app"]}]},
         {"token":"figma","version":"126.8.18","url":"https://f","sha256":"no_check",
          "artifacts":[{"app":["Figma.app"]}]},
         {"token":"visual-studio-code","version":"1.139.1","url":"https://c","sha256":"abc",
          "artifacts":[{"app":["Visual Studio Code.app"]}]}]
        """.utf8).write(to: catalogue.appendingPathComponent("cask.json"))

        let finder = UpdateFinder(fetch: { request in
            guard request.url?.host == "itunes.apple.com" else { throw URLError(.notConnectedToInternet) }
            let body = #"{"results":[{"bundleId":"net.whatsapp.WhatsApp","version":"26.37.76","trackId":1}]}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, catalogueDirectory: catalogue, platform: sequoia, installedCasks: [])

        let check = await finder.check([store, figma, code])
        XCTAssertEqual(check.updates.map(\.name), ["Visual Studio Code"])
        XCTAssertEqual(check.updates.first?.download?.integrity, .sha256("abc"))
        XCTAssertEqual(check.checked, 3)
        XCTAssertTrue(check.unchecked.isEmpty)
    }

    /// Prime Video's App Store listing is shared with iPhone and iPad, and
    /// its version, 10.150.2, was the iPhone's. The Mac build was 10.148 and
    /// the App Store offered nothing, while Brim offered an update. The Mac
    /// page decides for a shared listing, and one that cannot be read is
    /// not checked rather than guessed.
    func testASharedStoreListingIsCheckedAgainstTheMacPage() async throws {
        let video = try app("Prime Video", "com.amazon.aiv.AIVApp", "10.148", receipt: true)
        let blocker = try app("uBlock Origin Lite", "net.raymondhill.uBlock-Origin-Lite", "2026.920.1710", receipt: true)
        let silent = try app("Silent", "com.example.silent", "1.0", receipt: true)
        let finder = UpdateFinder(fetch: { request in
            let url = request.url!
            let ok = { (body: String) in
                (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if url.host == "itunes.apple.com" {
                return ok(#"{"results":["#
                    + #"{"bundleId":"com.amazon.aiv.AIVApp","kind":"software","version":"10.150.2","trackId":1},"#
                    + #"{"bundleId":"net.raymondhill.uBlock-Origin-Lite","kind":"software","version":"2026.926.2202","trackId":2},"#
                    + #"{"bundleId":"com.example.silent","kind":"software","version":"2.0","trackId":3}]}"#)
            }
            switch url.path {
            case "/in/app/id1": return ok(#"<p>{"primarySubtitle":"Version 10.148"}</p>"#)
            case "/in/app/id2": return ok(#"<span class="x">Version 2026.926.2202</span>"#)
            default: throw URLError(.notConnectedToInternet)
            }
        }, catalogueDirectory: folder.appendingPathComponent("none"), platform: sequoia, region: "IN", installedCasks: [])

        let check = await finder.check([video, blocker, silent])
        XCTAssertEqual(check.updates.map(\.name), ["uBlock Origin Lite"])
        XCTAssertEqual(check.updates.first?.latestVersion, "2026.926.2202")
        XCTAssertEqual(check.unchecked.map(\.name), ["Silent"])
    }

    /// No source means not checked, never up to date.
    func testAnApplicationNoSourceAnswersForIsNotCheckedRatherThanCurrent() async throws {
        let lonely = try app("Lonely", "com.example.lonely", "1.0")
        let finder = UpdateFinder(fetch: { _ in throw URLError(.notConnectedToInternet) },
                                  catalogueDirectory: folder.appendingPathComponent("none"),
                                  platform: sequoia, installedCasks: [])
        let check = await finder.check([lonely])
        XCTAssertEqual(check.checked, 0)
        XCTAssertEqual(check.unchecked.map(\.name), ["Lonely"])
    }

    private func app(_ name: String, _ bundleID: String, _ version: String, receipt: Bool = false) throws
        -> InstalledApplication {
        let url = folder.appendingPathComponent("\(name).app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleVersion": version
        ], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        if receipt {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("_MASReceipt"),
                                                    withIntermediateDirectories: true)
            try Data([1]).write(to: contents.appendingPathComponent("_MASReceipt/receipt"))
        }
        return InstalledApplication(identity: Identity(bundleID: bundleID, name: name, version: version),
                                    url: url, bundleSizeBytes: 1, isSystemProtected: false)
    }
}
