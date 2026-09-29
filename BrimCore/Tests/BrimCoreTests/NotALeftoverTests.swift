@testable import BrimCore
@testable import BrimScan
import XCTest

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

    private func bundle(_ relative: String, identifier: String, name: String? = nil) throws -> URL {
        var info = ["CFBundleIdentifier": identifier]
        info["CFBundleName"] = name
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        _ = try put(relative + "/Contents/Info.plist", contents: plist)
        return rootURL.appendingPathComponent(relative)
    }

    private func listed() async throws -> Set<String> {
        let found = try await LeftoversScanner(root: root, hasFullDiskAccess: true).scanLeftovers()
        return Set(found.map(\.url.lastPathComponent))
    }

    /// Teams and Microsoft AutoUpdate were both removed, and
    /// `/Library/Logs/Microsoft` still held their logs while
    /// `Application Support/Microsoft/Office365` stayed as well. Neither
    /// folder name has dots in it, so the sweep read both as macOS's and never
    /// looked inside. The person found them in Finder.
    func testADevelopersPlainFolderInLibraryIsLookedInside() async throws {
        _ = try put("Library/Logs/Microsoft/MSTeams/teams.log", contents: Data([1]))
        _ = try put("Library/Logs/Microsoft/autoupdate.log", contents: Data([1]))
        _ = try put("Library/Application Support/Microsoft/Office365/licence.dat", contents: Data([1]))
        // macOS's own plain folders stay out, including one an Apple
        // application's name begins with.
        _ = try put("Library/Application Support/Apple/ParentalControls/data", contents: Data([1]))
        _ = try put("Library/Caches/ColorSync/Profiles/data", contents: Data([1]))
        _ = try bundle("System/Applications/Utilities/ColorSync Utility.app",
                       identifier: "com.apple.ColorSyncUtility", name: "ColorSync Utility")

        let found = try await LeftoversScanner(root: root, hasFullDiskAccess: true).scanLeftovers(
            knownNames: ["com.microsoft.teams2": "Microsoft Teams", "com.example.sync": "ColorSync Studio"]
        )
        let names = Set(found.map(\.url.lastPathComponent))
        XCTAssertTrue(names.isSuperset(of: ["MSTeams", "autoupdate.log", "Office365"]), "\(names)")
        XCTAssertFalse(names.contains("Microsoft"), "The developer's folder is never offered whole")
        XCTAssertFalse(names.contains("ParentalControls"))
        XCTAssertFalse(names.contains("Profiles"), "ColorSync is Apple's name")
        XCTAssertEqual(found.first { $0.url.lastPathComponent == "MSTeams" }?.evidence,
                       "In Microsoft's folder. Nothing from Microsoft is installed.")
    }

    /// While AutoUpdate is installed it is an application, not a leftover,
    /// and what Microsoft keeps beside it may be what it uses.
    func testADevelopersFolderStaysWhileItsSoftwareIsInstalled() async throws {
        let receipt = try PropertyListSerialization.data(fromPropertyList: [
            "InstallPrefixPath": "Library/Application Support/Microsoft/MAU2.0"
        ], format: .xml, options: 0)
        _ = try put("private/var/db/receipts/com.microsoft.package.Microsoft_AutoUpdate.app.plist",
                    contents: receipt)
        _ = try bundle("Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app",
                       identifier: "com.microsoft.autoupdate2", name: "Microsoft AutoUpdate")
        _ = try put("Library/Application Support/Microsoft/Office365/licence.dat", contents: Data([1]))
        _ = try put("Library/Logs/Microsoft/autoupdate.log", contents: Data([1]))

        let names = try await listed()
        XCTAssertFalse(names.contains("MAU2.0"), "The folder an installed application runs from")
        XCTAssertFalse(names.contains("Office365"))
        XCTAssertFalse(names.contains("autoupdate.log"))
    }

    /// A plug-in bundle's file name is two words at most, `Flash
    /// Player.prefPane`, so the rule that keeps macOS's plainly named
    /// folders out of the sweep kept every third-party plug-in in `/Library`
    /// out as well. A bundle says whose it is in its `Info.plist`.
    func testAPlugInBundleInLibraryIsJudgedByItsIdentifier() async throws {
        _ = try bundle("Library/PreferencePanes/Flash Player.prefPane",
                       identifier: "com.adobe.flashplayer.installmanager")
        _ = try put("Library/PreferencePanes/Flash Player.prefPane/Contents/Resources/data", contents: Data([1]))
        _ = try bundle("Library/QuickLook/Viewer.qlgenerator", identifier: "com.example.viewer.quicklook")
        _ = try put("Library/QuickLook/Viewer.qlgenerator/Contents/MacOS/Viewer", contents: Data([1]))
        _ = try bundle("Library/PreferencePanes/Network Link.prefPane", identifier: "com.apple.preference.link")

        let names = try await listed()
        XCTAssertTrue(names.isSuperset(of: ["Flash Player.prefPane", "Viewer.qlgenerator"]), "\(names)")
        XCTAssertFalse(names.contains("Network Link.prefPane"))
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
