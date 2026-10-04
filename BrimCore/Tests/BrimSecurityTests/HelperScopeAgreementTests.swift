import BrimCore
@testable import BrimPrivileged
import XCTest

/// The plan promises only what the helper will do.
///
/// The planner cannot import the helper's rules, so it keeps its own
/// reading of them in `HelperScope`. Two readings of one fact is how this
/// codebase keeps breaking, so they are held to one answer here: a folder
/// added to the helper and not to the plan would be refused silently, and
/// one added to the plan and not the helper would be promised and then
/// refused after approval, which is the incident that started this.
final class HelperScopeAgreementTests: XCTestCase {
    func testThePlanAndTheHelperNameTheSameJobFolders() {
        XCTAssertEqual(
            HelperScope.jobFolders,
            Set(PrivilegedJobRemoval.Domain.allCases.map(\.directory))
        )
    }

    func testThePlanAndTheHelperNameTheSameCommandFolders() {
        XCTAssertEqual(
            HelperScope.commandFolders,
            Set(PrivilegedLinkRemoval.Domain.allCases.map(\.directory))
        )
    }

    func testThePlanAndTheHelperNameTheSameBundleFolders() {
        XCTAssertEqual(
            HelperScope.bundleFolders,
            Dictionary(uniqueKeysWithValues: PrivilegedBundleRemoval.Domain.allCases.map {
                ($0.directory, $0.extensions)
            })
        )
    }

    /// A root helper that moves bundles has to refuse by its own reading,
    /// whatever it is asked: nothing that is not a plain name with the
    /// place's own extension, and nothing macOS's or Brim's.
    func testTheHelperRefusesAnythingButAnInstalledBundle() throws {
        XCTAssertThrowsError(try PrivilegedBundleRemoval.target(domain: "applications", name: "../Safari.app"))
        XCTAssertThrowsError(try PrivilegedBundleRemoval.target(domain: "applications", name: "notes.txt"))
        XCTAssertThrowsError(try PrivilegedBundleRemoval.target(domain: "halPlugIns", name: "Vendor.app"))
        XCTAssertThrowsError(try PrivilegedBundleRemoval.target(domain: "library", name: "Vendor.app"))
        XCTAssertEqual(try PrivilegedBundleRemoval.target(domain: "applications", name: "Vendor.app").path,
                       "/Applications/Vendor.app")

        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bundle-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        for (name, identifier) in [("Apple.app", "com.apple.Notes"), ("Brim.app", "com.sabharishhh.brim")] {
            let contents = folder.appendingPathComponent("\(name)/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier],
                                               format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            XCTAssertThrowsError(try PrivilegedBundleRemoval.check(bundle: folder.appendingPathComponent(name)))
        }
    }

    func testThePlanAndTheHelperNameTheSameCacheFolders() {
        XCTAssertEqual(HelperScope.cacheFolders, [PrivilegedCacheRemoval.directory])
        XCTAssertThrowsError(try PrivilegedCacheRemoval.target(name: "com.apple.aned"))
        XCTAssertThrowsError(try PrivilegedCacheRemoval.target(name: "../Keychains"))
        XCTAssertThrowsError(try PrivilegedCacheRemoval.target(name: "com.sabharishhh.brim"))
        XCTAssertEqual(try PrivilegedCacheRemoval.target(name: "com.vendor.updater").path,
                       "/Library/Caches/com.vendor.updater")
    }

    /// Microsoft AutoUpdate's `com.microsoft.autoupdate2.plist` in
    /// `/Library/Preferences` was the one thing a review could not take, so
    /// the app stayed listed with something left. Files named like a bundle
    /// identifier only; folders there are how this Mac is set up.
    func testThePlanAndTheHelperNameTheSamePreferenceFiles() {
        XCTAssertEqual(HelperScope.preferenceFolders, [PrivilegedPreferenceRemoval.directory])
        XCTAssertEqual(try PrivilegedPreferenceRemoval.target(name: "com.microsoft.autoupdate2.plist").path,
                       "/Library/Preferences/com.microsoft.autoupdate2.plist")
        for refused in ["com.apple.loginwindow.plist", ".GlobalPreferences.plist", "SystemConfiguration",
                        "Audio", "../Keychains", "com.sabharishhh.brim.plist", "vendor.plist", "org.cups.printers.plist"] {
            XCTAssertThrowsError(try PrivilegedPreferenceRemoval.target(name: refused), refused)
            XCTAssertFalse(HelperScope.covers("/Library/Preferences/\(refused)"), refused)
        }
    }

    /// An application an installer put in Application Support is taken
    /// only on the package's own receipt, and the plan reads the receipt
    /// the way the helper does. Microsoft AutoUpdate, left by Teams, is
    /// the case this exists for.
    func testThePlanAndTheHelperReadAPackagesInstallFolderTheSameWay() throws {
        let receipts = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("receipts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: receipts) }
        let prefixes = [
            "com.vendor.updater": "Library/Application Support/Vendor/MAU2.0",
            "com.vendor.shallow": "Library/Application Support",
            "com.vendor.system": "System/Library/Vendor/Thing",
            "com.vendor.security": "Library/Security/Vendor/Thing",
            "com.apple.pkg.Thing": "Library/Application Support/Apple/Thing"
        ]
        for (package, prefix) in prefixes {
            try PropertyListSerialization.data(fromPropertyList: ["InstallPrefixPath": prefix], format: .binary, options: 0)
                .write(to: receipts.appendingPathComponent("\(package).plist"))
        }
        let paths = [
            "/Library/Application Support/Vendor/MAU2.0/Vendor Updater.app",
            "/Library/Application Support/Vendor/MAU2.0/Nested/Vendor Updater.app",
            "/Library/Application Support/Vendor/MAU2.0/notes.txt",
            "/Library/Application Support/Other.app",
            "/System/Library/Vendor/Thing/Other.app",
            "/Library/Security/Vendor/Thing/Other.app",
            "/Library/Application Support/Apple/Thing/Other.app"
        ]
        for path in paths {
            XCTAssertEqual(HelperScope.payloadPackage(for: path, receipts: receipts),
                           PrivilegedPayloadRemoval.package(for: path, receipts: receipts), path)
        }
        XCTAssertEqual(HelperScope.payloadPackage(for: paths[0], receipts: receipts), "com.vendor.updater")
        XCTAssertEqual(paths.dropFirst().compactMap { HelperScope.payloadPackage(for: $0, receipts: receipts) }, [])
        XCTAssertThrowsError(try PrivilegedPayloadRemoval.target(packageID: "com.vendor.updater", name: "../x.app",
                                                                  receipts: receipts))
        XCTAssertThrowsError(try PrivilegedPayloadRemoval.target(packageID: "../com.vendor.updater", name: "x.app",
                                                                  receipts: receipts))
    }

    func testTheHelperIsNeverPromisedAnythingElse() {
        for path in [
            "/Library/Preferences/org.cups.printers.plist",
            "/Library/Application Support/Vendor",
            "/Library/LaunchAgents/com.apple.something.plist",
            "/Library/LaunchAgents/.hidden.plist",
            "/usr/bin/ls",
            "/usr/local/bin/sub/tool"
        ] {
            XCTAssertFalse(HelperScope.covers(path), path)
        }
        XCTAssertTrue(HelperScope.covers("/Library/LaunchDaemons/com.vendor.updater.plist"))
    }

    func testTheDeadLinkRuleMatchesTheHelpers() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("real"))
        let cases: [(String, String?)] = [
            ("dead", "missing"), ("alive", "real"), ("loop-a", "loop-b"), ("loop-b", "loop-a"),
            ("file", nil)
        ]
        for (name, destination) in cases {
            let path = directory.appendingPathComponent(name).path
            if let destination {
                try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
            } else {
                try Data().write(to: URL(fileURLWithPath: path))
            }
        }

        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        defer { close(descriptor) }
        for (name, _) in cases {
            let helperSaysDead = (try? PrivilegedLinkRemoval.deadDestination(parent: descriptor, name: name)) != nil
            XCTAssertEqual(
                HelperScope.isDeadLink(directory.appendingPathComponent(name).path), helperSaysDead, name
            )
        }
    }
}
