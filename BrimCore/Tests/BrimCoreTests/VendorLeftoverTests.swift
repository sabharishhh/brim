import BrimCore
@testable import BrimScan
import Foundation
import XCTest

/// A developer's leftovers are one thing when nothing of theirs is installed.
///
/// On 6 October seven of Adobe's folders sat in `HTTPStorages` with no Adobe
/// software left on the Mac. The sweep found all seven, but grouped them by
/// product into seven rows of a few kilobytes each, and Remnants lists an
/// unclaimed group only from a megabyte up. Only the one an installer had
/// left owned by root was listed, because it could not be removed, and the
/// rest were found by hand in Finder.
final class VendorLeftoverTests: XCTestCase {
    private let names = [
        "com.vendorco.setup", "com.vendorco.desktop.helper", "com.vendorco.crashreporter",
        "com.vendorco.LogTransport.LogTransport", "com.other.thing"
    ]

    private func sweep(installing identifier: String?) async throws -> [Leftover] {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("brim-vendor-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let root = FileSystemRoot(rootURL: base, userName: "tester")
        let storages = root.url(for: .userHTTPStorages)
        let old = Date(timeIntervalSinceNow: -90 * 86400)
        for name in names {
            let folder = storages.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("httpstorages.sqlite")
            try Data(repeating: 1, count: 2048).write(to: file)
            for path in [file.path, folder.path] {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
            }
        }
        if let identifier {
            let app = root.url(for: .applications).appendingPathComponent("Viewer.app/Contents")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
                                                                  "CFBundleName": "Viewer"], format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Info.plist"))
        }
        return try await LeftoversScanner(root: root).scanLeftovers()
    }

    func testNothingInstalledFromADeveloperMakesTheirLeftoversOneGroup() async throws {
        let groups = try await sweep(installing: nil).filter { $0.category == .unclaimed }.groupedByOwner()
        let vendor = try XCTUnwrap(groups.first { $0.groupKey == "vendor:com.vendorco" })
        XCTAssertEqual(vendor.displayName, "Vendorco")
        XCTAssertEqual(vendor.items.count, 4)
        // Another developer's single folder is its own, as before.
        XCTAssertTrue(groups.contains { $0.groupKey == "vendor:com.other" && $0.items.count == 1 })
    }

    /// While anything of the developer's is installed, a namespace is not
    /// an application: each product stays its own row.
    func testAnInstalledAppKeepsEachProductApart() async throws {
        let groups = try await sweep(installing: "com.vendorco.viewer").filter { $0.category == .unclaimed }
            .groupedByOwner()
        XCTAssertFalse(groups.contains { $0.groupKey.hasPrefix("vendor:com.vendorco") })
        XCTAssertTrue(groups.contains { $0.groupKey == "com.vendorco.setup" })
        XCTAssertTrue(groups.contains { $0.groupKey == "com.vendorco.crashreporter" })
    }

    func testOnlyOneDevelopersNamespaceIsAVendor() {
        XCTAssertEqual(OwnerNamespace.vendor(for: "com.vendorco.desktop.helper"), "com.vendorco")
        XCTAssertEqual(OwnerNamespace.vendor(for: "com.vendorco.app.plist"), "com.vendorco")
        XCTAssertNil(OwnerNamespace.vendor(for: "com.apple.akd"))
        XCTAssertNil(OwnerNamespace.vendor(for: "io.github.someone.tool"))
        XCTAssertNil(OwnerNamespace.vendor(for: "jp.co.nikon.tool"))
        XCTAssertNil(OwnerNamespace.vendor(for: "Vendorco Prefs"))
        XCTAssertEqual(OwnerNamespace.vendorDisplayName("com.vendorco"), "Vendorco")
    }

    /// Remnants offered Microsoft's `UBF8T346G9.ms` while Visual Studio Code,
    /// signed by the same team, was installed and its removal held it.
    func testATeamsSharedContainerStaysWhileATeamAppIsInstalled() {
        let teams: Set = ["UBF8T346G9"]
        XCTAssertTrue(LeftoversScanner.isActiveGroup("UBF8T346G9.ms", groups: [], teams: teams, bundleIDs: [],
                                                     names: []))
        XCTAssertTrue(LeftoversScanner.isActiveGroup("UBF8T346G9.Office", groups: [], teams: teams, bundleIDs: [],
                                                     names: []))
        // A removed product's own container is still offered.
        XCTAssertFalse(LeftoversScanner.isActiveGroup("UBF8T346G9.com.microsoft.teams", groups: [], teams: teams,
                                                      bundleIDs: ["com.microsoft.VSCode"], names: []))
        // With nothing of that team installed, nothing protects it.
        XCTAssertFalse(LeftoversScanner.isActiveGroup("UBF8T346G9.ms", groups: [], teams: ["ABCDE12345"],
                                                      bundleIDs: [], names: []))
    }
}

/// An installer that ran as an administrator left a folder owned by root
/// in the person's own `HTTPStorages`, and the reason given was that their
/// own folder belonged to the system.
final class AdministratorOwnedItemWordingTests: XCTestCase {
    func testAnItemLeftOwnedByRootInAHomeFolderIsNotCalledTheSystems() throws {
        let home = try XCTUnwrap(RemovalCapability.folderExplanation(.needsHelper,
                                                                     folder: "/Users/me/Library/HTTPStorages"))
        XCTAssertFalse(home.contains("belongs to the system"))
        XCTAssertTrue(home.contains("Finder"))
        let system = try XCTUnwrap(RemovalCapability.folderExplanation(.needsHelper, folder: "/Library/Caches"))
        XCTAssertTrue(system.contains("belongs to the system"))
    }
}
