import XCTest
@testable import BrimCore
@testable import BrimScan

/// Things that need an administrator are mostly not leftovers.
///
/// Measured on a real Mac: of twenty rows the sweep listed in root-owned
/// folders, three belonged to software that was still there. macOS's own
/// printer list, `/Library/Preferences/org.cups.printers.plist`, was
/// offered as unclaimed. So was `ParrotAudioPlugin.driver`, whose own
/// `Info.plist` says `com.apple.audio.ParrotAudioPlugin`, and
/// `MSTeamsAudioDevice.driver` with Microsoft Teams installed. Offering any
/// of them is how a leftover list stops being believed.
final class NotALeftoverTests: XCTestCase {

    private var rootURL: URL!
    private var root: FileSystemRoot!

    override func setUpWithError() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-leftover-\(UUID().uuidString)")
        root = FileSystemRoot(rootURL: rootURL, userName: "tester")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func put(_ relative: String, contents: Data = Data()) throws -> URL {
        let url = rootURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url)
        return url
    }

    private func bundle(_ relative: String, identifier: String) throws -> URL {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0
        )
        _ = try put(relative + "/Contents/Info.plist", contents: plist)
        return rootURL.appendingPathComponent(relative)
    }

    private func listed() async throws -> Set<String> {
        let found = try await LeftoversScanner(root: root, hasFullDiskAccess: true).scanLeftovers()
        return Set(found.map(\.url.lastPathComponent))
    }

    func testMacOSsPrinterListIsNotALeftover() async throws {
        _ = try put("System/Library/LaunchDaemons/org.cups.cupsd.plist")
        _ = try put("Library/Preferences/org.cups.printers.plist")
        _ = try put("Library/Preferences/com.vendor.gone.plist")

        let names = try await listed()
        XCTAssertFalse(names.contains("org.cups.printers.plist"), "The same family macOS ships")
        XCTAssertTrue(names.contains("com.vendor.gone.plist"), "Still finds a real one")
    }

    func testABundleThatSaysItIsApplesIsNotALeftover() async throws {
        _ = try bundle(
            "Library/Audio/Plug-Ins/HAL/ParrotAudioPlugin.driver",
            identifier: "com.apple.audio.ParrotAudioPlugin"
        )
        _ = try bundle(
            "Library/Audio/Plug-Ins/HAL/GoneVendor.driver", identifier: "com.gonevendor.audio"
        )

        let names = try await listed()
        XCTAssertFalse(names.contains("ParrotAudioPlugin.driver"))
        XCTAssertTrue(names.contains("GoneVendor.driver"))
    }

    /// Signing can only be decided on a real signature, so the rule is
    /// held on its own: a bundle signed by a team that also signed an
    /// installed application is that vendor's, and a present vendor may
    /// still be using it.
    func testABundleSignedByAnInstalledVendorIsTheirs() {
        XCTAssertTrue(LeftoversScanner.belongsToInstalledSoftware(
            identifier: "com.microsoft.MSTeamsAudioDevice", team: "UBF8T346G9",
            activeTeams: ["UBF8T346G9"]
        ))
        XCTAssertTrue(LeftoversScanner.belongsToInstalledSoftware(
            identifier: "com.apple.audio.ParrotAudioPlugin", team: nil, activeTeams: []
        ))
        XCTAssertFalse(LeftoversScanner.belongsToInstalledSoftware(
            identifier: "com.gonevendor.audio", team: "ABCDE12345", activeTeams: ["UBF8T346G9"]
        ))
        XCTAssertFalse(LeftoversScanner.belongsToInstalledSoftware(
            identifier: nil, team: nil, activeTeams: ["UBF8T346G9"]
        ))
    }
}
