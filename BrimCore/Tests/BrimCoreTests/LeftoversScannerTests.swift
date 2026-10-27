@testable import BrimCore
@testable import BrimScan
import Darwin
import Foundation
import XCTest

final class LeftoversScannerTests: XCTestCase {
    private func installApp(at app: URL) throws {
        let executable = app.appendingPathComponent("Contents/MacOS/TestApp")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // A real code object makes entitlement inspection possible. It is never run.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let infoPlistData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.TestApp",
                "CFBundleName": "TestApp",
                "CFBundleExecutable": "TestApp"
            ],
            format: .xml,
            options: 0
        )
        try infoPlistData.write(to: app.appendingPathComponent("Contents/Info.plist"))
    }

    func testActiveAppGroupContainersAndAppSupportNotMarkedAsLeftovers() async throws {
        let rawTempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: rawTempDir, withIntermediateDirectories: true)
        let tempDir = rawTempDir.resolvingSymlinksInPath()
        let root = FileSystemRoot(rootURL: tempDir, userName: "testuser")

        let appURL = root.url(for: .applications).appendingPathComponent("TestApp.app")
        try fm.createDirectory(at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)

        try installApp(at: appURL)

        // Active group container with team ID prefix
        let groupContainerURL = root.url(for: .userGroupContainers).appendingPathComponent("TEAM12345.com.example.TestApp")
        try fm.createDirectory(at: groupContainerURL, withIntermediateDirectories: true)
        try "group data".write(to: groupContainerURL.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        // Active Application Support using app name rather than bundle ID
        let appSupportURL = root.url(for: .userApplicationSupport).appendingPathComponent("TestApp")
        try fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        try "app support data".write(to: appSupportURL.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let helper = root.url(for: .userCaches)
            .appendingPathComponent("com.example.TestApp.helper")
        try fm.createDirectory(at: helper, withIntermediateDirectories: true)
        try "cache".write(to: helper.appendingPathComponent("data"),
                          atomically: true, encoding: .utf8)

        // Orphaned app support directory (with installer receipt)
        let receiptsDir = tempDir.appendingPathComponent("var/db/receipts")
        try fm.createDirectory(at: receiptsDir, withIntermediateDirectories: true)
        try "receipt".write(to: receiptsDir.appendingPathComponent("com.old.orphaned.plist"), atomically: true, encoding: .utf8)
        let orphanedURL = root.url(for: .userApplicationSupport).appendingPathComponent("com.old.orphaned")
        try fm.createDirectory(at: orphanedURL, withIntermediateDirectories: true)

        // An unclaimed folder with something in it: an empty unnamed folder is left
        // out, and this tests attribution, not that filter.
        let unclaimedURL = root.url(for: .userApplicationSupport).appendingPathComponent("MysteryTool")
        try fm.createDirectory(at: unclaimedURL, withIntermediateDirectories: true)
        try "mystery".write(
            to: unclaimedURL.appendingPathComponent("data.bin"),
            atomically: true, encoding: .utf8
        )

        let scanner = LeftoversScanner(root: root)
        let leftovers = try await scanner.scanLeftovers()
        // 1. Active group container must NOT be in leftovers
        let leftoverNames = leftovers.map(\.url.lastPathComponent)
        XCTAssertFalse(leftoverNames.contains(groupContainerURL.lastPathComponent), "Active group container should not be identified as leftover")

        // 2. Active application support must NOT be in leftovers
        XCTAssertFalse(leftoverNames.contains(appSupportURL.lastPathComponent), "Active application support directory should not be identified as leftover")
        XCTAssertFalse(leftoverNames.contains(helper.lastPathComponent), "An installed app owns its helper data")

        // 3. Orphaned app support must be identified as .orphaned
        let orphanedMatch = leftovers.first(where: { $0.url.lastPathComponent == orphanedURL.lastPathComponent })
        XCTAssertNotNil(orphanedMatch, "Orphaned item should be detected")
        XCTAssertEqual(orphanedMatch?.category, .orphaned)

        // 4. Truly unclaimed item must be identified as .unclaimed
        let unclaimedMatch = leftovers.first(where: { $0.url.lastPathComponent == unclaimedURL.lastPathComponent })
        XCTAssertNotNil(unclaimedMatch, "Unclaimed item should be detected")
        XCTAssertEqual(unclaimedMatch?.category, .unclaimed)
    }
}

/// Apple's own data is never offered, including group containers named
/// `group.com.apple.*`.
final class AppleOwnedFilterTests: XCTestCase {
    func testSystemNamesComeFromFixtureSystemLibrary() throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: raw) }
        let frameworks = raw.appendingPathComponent("System/Library/PrivateFrameworks")
        try FileManager.default.createDirectory(
            at: frameworks.appendingPathComponent("SampleDaemon.framework"),
            withIntermediateDirectories: true
        )
        let names = LeftoversScanner.systemNames(in: FileSystemRoot(rootURL: raw))
        XCTAssertTrue(LeftoversScanner.isInstalledSystemComponent("SampleDaemon", names: names))
        XCTAssertFalse(LeftoversScanner.isInstalledSystemComponent("ThirdParty", names: names))
    }

    func testSystemDataIsNeverOfferedInEitherSpelling() {
        XCTAssertTrue(LeftoversScanner.isAppleOwned("com.apple.Safari"))
        XCTAssertTrue(LeftoversScanner.isAppleOwned("group.com.apple.SHTTS"))
        XCTAssertTrue(LeftoversScanner.isAppleOwned("group.com.apple.gamecenter"))
        XCTAssertTrue(LeftoversScanner.isAppleOwned("systemgroup.com.apple.icloud.searchpartyd.sharedsettings.plist"))
        XCTAssertTrue(LeftoversScanner.isAppleOwned("com.apple"))
    }

    func testSeparatelyShippedAppleSoftwareStaysRemovable() {
        // Logic and Final Cut are bought and removed like anything else.
        XCTAssertFalse(LeftoversScanner.isAppleOwned("com.apple.logic10"))
        XCTAssertFalse(LeftoversScanner.isAppleOwned("com.apple.FinalCut"))
    }

    func testThirdPartySoftwareIsUnaffected() {
        XCTAssertFalse(LeftoversScanner.isAppleOwned("com.figma.Desktop"))
        XCTAssertFalse(LeftoversScanner.isAppleOwned("group.com.acme.shared"))
        XCTAssertFalse(LeftoversScanner.isAppleOwned("Codex"))
        // Not a prefix match on something merely starting with the letters.
        XCTAssertFalse(LeftoversScanner.isAppleOwned("com.applesauce.jam"))
    }
}

/// Places the sweep missed: deeper levels and other domains. These hold the
/// three classes found when auditing what else was not looked at.
final class LeftoversScannerGapAuditTests: XCTestCase {
    private func makeRoot() throws -> (FileSystemRoot, URL) {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let tempDir = raw.resolvingSymlinksInPath()
        return (FileSystemRoot(rootURL: tempDir, userName: "testuser"), tempDir)
    }

    func testNestedInventoryRootsAndCrashReportsAreNotLeftoverRows() async throws {
        let (root, raw) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: raw) }
        let manager = FileManager.default
        for domain in [FileSystemRoot.Domain.userPreferencesByHost, .userDiagnosticReports, .userCaches] {
            try manager.createDirectory(at: root.url(for: domain), withIntermediateDirectories: true)
        }
        try "crash".write(
            to: root.url(for: .userDiagnosticReports).appendingPathComponent("GoneApp.crash"),
            atomically: true, encoding: .utf8
        )
        try "data".write(
            to: root.url(for: .userCaches).appendingPathComponent("GoneApp"),
            atomically: true, encoding: .utf8
        )

        let paths = try await Set(LeftoversScanner(root: root).scanLeftovers()
            .map { $0.url.resolvingSymlinksInPath().path })
        let cache = root.url(for: .userCaches).appendingPathComponent("GoneApp")
        XCTAssertTrue(paths.contains(cache.resolvingSymlinksInPath().path))
        XCTAssertFalse(paths.contains(root.url(for: .userDiagnosticReports).path))
        XCTAssertFalse(paths.contains(root.url(for: .userPreferencesByHost).path))
        let crash = root.url(for: .userDiagnosticReports).appendingPathComponent("GoneApp.crash")
        XCTAssertFalse(paths.contains(crash.path))
        // A searched crash-report root does not make an unrecorded owner a remnant.
    }

    func testRunningAppOutsideApplicationsProtectsItsCurrentAndOlderData() async throws {
        let (root, raw) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: raw) }
        let manager = FileManager.default
        let app = raw.appendingPathComponent("Developer/Brim.app")
        try manager.createDirectory(at: app.appendingPathComponent("Contents"),
                                    withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.sabharishhh.brim", "CFBundleName": "Brim"],
            format: .xml, options: 0
        )
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let support = root.url(for: .userApplicationSupport).appendingPathComponent("Brim")
        let preferences = root.url(for: .userPreferences)
            .appendingPathComponent("devplaceholder.PJ52YXEB.brim.plist")
        try manager.createDirectory(at: support, withIntermediateDirectories: true)
        try "data".write(to: support.appendingPathComponent("state"),
                         atomically: true, encoding: .utf8)
        try manager.createDirectory(at: preferences.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        try "old".write(to: preferences, atomically: true, encoding: .utf8)

        let ordinary = try await Set(LeftoversScanner(root: root).scanLeftovers()
            .map { $0.url.resolvingSymlinksInPath().path })
        XCTAssertTrue(ordinary.contains(support.resolvingSymlinksInPath().path))
        XCTAssertTrue(ordinary.contains(preferences.resolvingSymlinksInPath().path))
        let protected = try await Set(LeftoversScanner(root: root, protectedAppURL: app)
            .scanLeftovers().map { $0.url.resolvingSymlinksInPath().path })
        XCTAssertFalse(protected.contains(support.resolvingSymlinksInPath().path))
        XCTAssertFalse(protected.contains(preferences.resolvingSymlinksInPath().path))
    }

    func testContainerMetadataSeparatesProductsCreatedTogether() async throws {
        let (root, raw) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: raw) }
        let manager = FileManager.default
        let containers = root.url(for: .userContainers)
        let owners = [
            "com.example.alpha.Notification", "com.example.alpha.Widget",
            "com.other.beta.Widget"
        ]
        for owner in owners {
            let url = containers.appendingPathComponent(UUID().uuidString)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            try "data".write(to: url.appendingPathComponent("state"),
                             atomically: true, encoding: .utf8)
            let result = Array(owner.utf8).withUnsafeBytes {
                setxattr(url.path, "com.apple.containermanager.identifier",
                         $0.baseAddress, $0.count, 0, 0)
            }
            XCTAssertEqual(result, 0)
        }

        let leftovers = try await LeftoversScanner(root: root).scanLeftovers()
        XCTAssertEqual(leftovers.count, 3)
        XCTAssertTrue(leftovers.allSatisfy { $0.category == .orphaned })
        XCTAssertTrue(leftovers.allSatisfy { $0.evidence.contains("Container metadata") })
        let groups = leftovers.groupedByOwner()
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(Set(groups.compactMap(\.identifier)), Set(owners))
        XCTAssertTrue(groups.allSatisfy { $0.items.count == 1 })

        let live = raw.appendingPathComponent("Developer/Live.app")
        try manager.createDirectory(at: live, withIntermediateDirectories: true)
        let withLiveParent = try await LeftoversScanner(
            root: root,
            launchServicesLookup: { $0 == "com.example.alpha" ? [live] : [] }
        ).scanLeftovers()
        XCTAssertEqual(withLiveParent.count, 1)
        XCTAssertEqual(
            withLiveParent.first?.potentialOwner?.name, "Other beta",
            "developer and product, not the product label alone"
        )
    }

    func testMacOSRelocationFolderIsNotSoftwareResidue() async throws {
        let (root, raw) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: raw) }
        let shared = root.url(for: .sharedUser)
        let migrated = shared.appendingPathComponent("Previously Relocated Items 2")
        let unrelated = shared.appendingPathComponent("Previously Relocated Items notes")
        try FileManager.default.createDirectory(at: migrated, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        for folder in [migrated, unrelated] {
            try "data".write(to: folder.appendingPathComponent("record"),
                             atomically: true, encoding: .utf8)
        }
        try "".write(to: migrated.appendingPathComponent(".localized"),
                     atomically: true, encoding: .utf8)

        let names = try await Set(LeftoversScanner(root: root).scanLeftovers()
            .map(\.url.lastPathComponent))
        XCTAssertFalse(names.contains(migrated.lastPathComponent))
        XCTAssertTrue(names.contains(unrelated.lastPathComponent))
    }

    private func writeApp(
        _ root: FileSystemRoot, folderName: String, bundleID: String, bundleName: String
    ) throws {
        let fm = FileManager.default
        let appURL = root.url(for: .applications).appendingPathComponent("\(folderName).app")
        try fm.createDirectory(at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleID, "CFBundleName": bundleName],
            format: .xml, options: 0
        )
        try data.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
    }

    /// A plain file's size is measured, not read as an empty directory; zero
    /// bytes dropped every preferences file from the sweep.
    func testPlainFileSizeIsMeasuredNotJustDirectorySize() async throws {
        let (root, _) = try makeRoot()
        let fm = FileManager.default
        let prefsDir = root.url(for: .userPreferences)
        try fm.createDirectory(at: prefsDir, withIntermediateDirectories: true)
        let content = String(repeating: "x", count: 512)
        let file = prefsDir.appendingPathComponent("com.ghost.vanished.plist")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let leftovers = try await LeftoversScanner(root: root).scanLeftovers()
        let match = leftovers.first { $0.url.lastPathComponent == "com.ghost.vanished.plist" }
        XCTAssertNotNil(match, "A real, sized preference file must not be dropped as if it were empty")
        XCTAssertEqual(match?.size, 512, "The file's own size, not zero from walking it as a directory")
    }

    /// A link in `/usr/local/bin` is judged by its target: one into something
    /// installed is not a leftover, one into something gone is a command that
    /// cannot run.
    func testDanglingSymlinkIsReportedByItsTargetNotItsName() async throws {
        let (root, tempDir) = try makeRoot()
        let fm = FileManager.default
        let binDir = root.url(for: .usrLocalBin)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        // Points into an application that was removed.
        let ghostTarget = tempDir
            .appendingPathComponent("Applications/Ghost.app/Contents/MacOS/ghost")
        try fm.createSymbolicLink(at: binDir.appendingPathComponent("ghost"), withDestinationURL: ghostTarget)

        // Points at a file that is still there, so it is not a leftover whatever it
        // is called.
        let realFile = tempDir.appendingPathComponent("real-tool")
        try "#!/bin/sh".write(to: realFile, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: binDir.appendingPathComponent("live"), withDestinationURL: realFile)

        let leftovers = try await LeftoversScanner(root: root).scanLeftovers()
        let names = leftovers.map(\.url.lastPathComponent)
        XCTAssertFalse(names.contains("live"), "A link to something still on disk is not a leftover")

        let dangling = leftovers.first { $0.url.lastPathComponent == "ghost" }
        XCTAssertNotNil(dangling, "A link into a removed application must be reported")
        XCTAssertEqual(dangling?.category, .orphaned)
        XCTAssertEqual(dangling?.size, 0)
        XCTAssertEqual(dangling?.potentialOwner?.name, "Ghost.app",
                       "Named by what it pointed at, not by its own link name")
    }

    /// A vendor folder holding a live product and a dead one is opened, so the
    /// dead one is seen.
    func testVendorFolderIsExpandedSoADeadProductBesideALiveOneIsSeen() async throws {
        let (root, _) = try makeRoot()
        let fm = FileManager.default
        try writeApp(root, folderName: "AnyApp", bundleID: "com.vendor.live", bundleName: "Vendor LiveProduct")

        let vendorDir = root.url(for: .userApplicationSupport).appendingPathComponent("Vendor")
        let liveDir = vendorDir.appendingPathComponent("LiveProduct")
        let deadDir = vendorDir.appendingPathComponent("DeadProduct")
        try fm.createDirectory(at: liveDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: deadDir, withIntermediateDirectories: true)
        try "still used".write(to: liveDir.appendingPathComponent("state"), atomically: true, encoding: .utf8)
        try "left behind".write(to: deadDir.appendingPathComponent("state"), atomically: true, encoding: .utf8)

        let leftovers = try await LeftoversScanner(root: root).scanLeftovers()
        let names = leftovers.map(\.url.lastPathComponent)
        XCTAssertFalse(names.contains("Vendor"), "The shared folder itself answers nothing about any product")
        XCTAssertFalse(names.contains("LiveProduct"), "The product a live application still uses is not a leftover")

        let dead = leftovers.first { $0.url.lastPathComponent == "DeadProduct" }
        XCTAssertNotNil(dead, "A dead product nested beside a live one must still be found")
        XCTAssertEqual(dead?.category, .unclaimed)
        XCTAssertEqual(dead?.potentialOwner?.name, "Vendor DeadProduct",
                       "Named with the vendor, or it reads next to nothing to a person")
    }

    /// A support folder named for the bundle's `CFBundleName` (Visual Studio
    /// Code's "Code") belongs to the installed app.
    func testApplicationSupportNamedAfterTheBundlesInternalNameIsRecognisedAsActive() async throws {
        let (root, _) = try makeRoot()
        let fm = FileManager.default
        try writeApp(root, folderName: "Visual Studio Code", bundleID: "com.microsoft.VSCode", bundleName: "Code")

        let codeDir = root.url(for: .userApplicationSupport).appendingPathComponent("Code")
        try fm.createDirectory(at: codeDir, withIntermediateDirectories: true)
        try "profile data".write(to: codeDir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

        let leftovers = try await LeftoversScanner(root: root).scanLeftovers()
        XCTAssertFalse(
            leftovers.map(\.url.lastPathComponent).contains("Code"),
            "A folder named after the bundle's own CFBundleName is that application's, not a leftover"
        )
    }
}

extension LeftoversScannerGapAuditTests {
    /// The real audit found the whole SentryCrash folder offered while an
    /// installed application's removal held a child inside it.
    func testSharedCrashCacheIsJudgedByItsChildren() async throws {
        let (root, folder) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeApp(root, folderName: "Live", bundleID: "org.example.live", bundleName: "Live")
        let cache = root.url(for: .userCaches).appendingPathComponent("SentryCrash")
        for child in ["Live", "org.example.gone"] {
            let directory = cache.appendingPathComponent(child)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("report".utf8).write(to: directory.appendingPathComponent("report"))
        }
        let leftovers = try await LeftoversScanner(root: root).scanLeftovers(
            knownPastBundleIDs: ["org.example.gone"], knownNames: ["org.example.gone": "Gone"]
        )
        let names = Set(leftovers.map(\.url.lastPathComponent))
        XCTAssertFalse(names.contains("SentryCrash"))
        XCTAssertFalse(names.contains("Live"))
        XCTAssertTrue(names.contains("org.example.gone"))
    }
}
