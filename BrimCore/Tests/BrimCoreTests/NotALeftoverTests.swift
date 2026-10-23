@testable import BrimCore
@testable import BrimScan
import XCTest

/// Most things that need an administrator are not leftovers: macOS's own
/// printer list, a driver whose `Info.plist` names Apple, and an installed
/// app's driver were all once offered.
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

    /// A developer's plainly named folder in `/Library` is looked inside, not
    /// read as macOS's because it has no dots.
    func testADevelopersPlainFolderInLibraryIsLookedInside() async throws {
        _ = try put("Library/Logs/Microsoft/MSTeams/teams.log", contents: Data([1]))
        _ = try put("Library/Logs/Microsoft/autoupdate.log", contents: Data([1]))
        _ = try put("Library/Application Support/Microsoft/Office365/licence.dat", contents: Data([1]))
        // macOS's own plain folders stay out, including one an Apple app's name
        // begins with.
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

    /// While the developer's software is installed, what it keeps beside it may
    /// be in use.
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

    /// A plug-in bundle in `/Library` is judged by the identifier its
    /// `Info.plist` declares, not its plain file name.
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

    /// Not leftovers: caches Developer already counts, a command line tool's
    /// own folder (`SwiftLint` for `swiftlint`), and macOS's own data.
    func testCachesAccountedForElsewhereAndMacOSsOwnDataAreNotLeftovers() async throws {
        let homebrew = try put("Users/tester/Library/Caches/Homebrew/downloads/bottle", contents: Data([1]))
            .deletingLastPathComponent().deletingLastPathComponent()
        _ = try put("Users/tester/Library/Caches/SwiftLint/cache", contents: Data([1]))
        _ = try put("Users/tester/Library/Application Support/CallHistoryDB/com.apple.callhistory.databaseInfo.plist",
                    contents: Data([1]))
        _ = try put("Users/tester/Library/Caches/GoneTool/cache", contents: Data([1]))

        let found = try await LeftoversScanner(
            root: root, claimedPaths: [homebrew.path], hasFullDiskAccess: true,
            commandIsInstalled: { $0 == "swiftlint" }
        ).scanLeftovers()
        let names = Set(found.map(\.url.lastPathComponent))
        XCTAssertFalse(names.contains("Homebrew"), "Developer counts it")
        XCTAssertFalse(names.contains("SwiftLint"), "an installed command's own folder")
        XCTAssertFalse(names.contains("CallHistoryDB"), "holds a file macOS names for itself")
        XCTAssertTrue(names.contains("GoneTool"), "still finds a real one")
    }

    /// An unnamed folder written this week belongs to something alive.
    func testAnUnnamedFolderWrittenThisWeekIsInUse() async throws {
        let old = Date(timeIntervalSinceNow: -60 * 24 * 60 * 60)
        let live = try put("Users/tester/Library/Application Support/Knowledge/knowledgeC.db", contents: Data([1]))
        let gone = try put("Users/tester/Library/Application Support/CEF/cache", contents: Data([1]))
        for url in [gone, gone.deletingLastPathComponent()] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        _ = live

        let found = try await LeftoversScanner(root: root, hasFullDiskAccess: true, inUseWithin: 7 * 24 * 60 * 60)
            .scanLeftovers()
        let names = Set(found.map(\.url.lastPathComponent))
        XCTAssertFalse(names.contains("Knowledge"))
        XCTAssertTrue(names.contains("CEF"), "untouched for two months, still listed")
    }

    /// A folder with a container's name (`Caches` in Application Support) is
    /// looked inside, and what is in it is named.
    func testAFolderNamedLikeAContainerIsLookedInside() async throws {
        _ = try put("Users/tester/Library/Application Support/Caches/notion-updater/pending/x.zip", contents: Data([1]))
        let found = try await LeftoversScanner(root: root, hasFullDiskAccess: true).scanLeftovers()
        let names = Set(found.map(\.url.lastPathComponent))
        XCTAssertFalse(names.contains("Caches"))
        XCTAssertTrue(names.contains("notion-updater"))
        XCTAssertEqual(found.first { $0.url.lastPathComponent == "notion-updater" }?.potentialOwner?.name, "Notion")
    }

    /// What a removed app left carries when Brim last saw the app, so it is
    /// counted as that app's.
    func testTracesOfAnAppHistorySawGoAreItsWithTheDate() async throws {
        _ = try put("Users/tester/Library/Preferences/com.microsoft.autoupdate2.plist", contents: Data([1]))
        let seen = Date(timeIntervalSince1970: 1_790_000_000)
        let found = try await LeftoversScanner(
            root: root,
            staleRegistrationOwners: [
                "com.microsoft.autoupdate2": "Brim saw Microsoft AutoUpdate installed until 28 Sep."
            ],
            removedApplications: ["com.microsoft.autoupdate2": seen],
            hasFullDiskAccess: true
        ).scanLeftovers(knownPastBundleIDs: ["com.microsoft.autoupdate2"],
                        knownNames: ["com.microsoft.autoupdate2": "Microsoft AutoUpdate"])
        let item = try XCTUnwrap(found.first { $0.url.lastPathComponent == "com.microsoft.autoupdate2.plist" })
        XCTAssertEqual(item.category, .orphaned)
        XCTAssertEqual(item.removedAt, seen)
        XCTAssertEqual(item.potentialOwner?.name, "Microsoft AutoUpdate")
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

    /// A bundle signed by a team that also signed an installed app is that
    /// vendor's, which may still use it.
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

    /// Home dot folders and crash reports are named only for a recorded removed
    /// app; `.ssh` and a stranger's crash report stay off the list.
    func testHomeDotFoldersAndCrashReportsAreNamedOnlyForARecordedApp() async throws {
        _ = try put("Users/tester/.antigravity-ide/argv.json", contents: Data([1]))
        _ = try put("Users/tester/.ssh/config", contents: Data([1]))
        _ = try put("Users/tester/Documents/antigravity/notes.txt", contents: Data([1]))
        _ = try put(
            "Library/Logs/DiagnosticReports/Tally_2026-09-29-090414_host.cpu_resource.diag",
            contents: Data([1])
        )
        _ = try put("Library/Logs/DiagnosticReports/Other-2026-09-29-090414.ips", contents: Data([1]))
        let found = try await LeftoversScanner(
            root: root,
            staleRegistrationOwners: ["com.google.antigravity": "Gone.", "com.example.tally.app": "Gone."],
            hasFullDiskAccess: true
        ).scanLeftovers(knownPastBundleIDs: ["com.google.antigravity", "com.example.tally.app"],
                        knownNames: ["com.google.antigravity": "Antigravity", "com.example.tally.app": "Tally"])
        let names = Dictionary(
            found.map { ($0.url.lastPathComponent, $0) },
            uniquingKeysWith: { application, _ in application }
        )
        XCTAssertEqual(names[".antigravity-ide"]?.potentialOwner?.name, "Antigravity")
        XCTAssertEqual(names["Tally_2026-09-29-090414_host.cpu_resource.diag"]?.category, .orphaned)
        XCTAssertNil(names[".ssh"])
        XCTAssertNil(names["Documents"])
        XCTAssertNil(names["Other-2026-09-29-090414.ips"])
    }

    /// `ChatGPTHelper.binarycookies` was listed as "Binarycookies".
    func testCookiesAreNamedForTheProcessNotTheExtension() async throws {
        _ = try put("Users/tester/Library/HTTPStorages/ChatGPTHelper.binarycookies", contents: Data([1]))
        let found = try await LeftoversScanner(root: root, hasFullDiskAccess: true).scanLeftovers()
        XCTAssertEqual(found.first { $0.url.lastPathComponent == "ChatGPTHelper.binarycookies" }?.potentialOwner?.name,
                       "ChatGPTHelper")
    }
}
