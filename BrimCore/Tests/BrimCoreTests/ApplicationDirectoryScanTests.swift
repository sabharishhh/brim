@testable import BrimCore
import Foundation
import Testing

struct ApplicationDirectoryScanTests {
    /// The old inventory reported dozens of "timeouts" in a 43 ms scan
    /// because resource folders were eight levels deep, not because time ran out.
    @Test func deepResourceTreesDoNotInventTimeoutsOrHideOtherApplications() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileSystemRoot(rootURL: folder, userName: "tester")
        let deep = root.url(for: .applications)
            .appendingPathComponent("Vendor/resources/one/two/three/four/five/six/seven/eight/nine/Helper.app")
        let user = root.url(for: .userApplications).appendingPathComponent("Editor.app")
        for app in [deep, user] {
            let info = app.appendingPathComponent("Contents/Info.plist")
            try FileManager.default.createDirectory(
                at: info.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.test.editor"],
                                               format: .xml, options: 0).write(to: info)
        }
        let inventory = InstalledBundleInventory.read(in: root)
        #expect(inventory.completeness.isComplete)
        #expect(Set(inventory.bundles.map(\.lastPathComponent)) == ["Helper.app", "Editor.app"])
        let empty = root.url(for: .applications).appendingPathComponent("Removed.app")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(InstalledBundleInventory.read(in: root).bundles.contains { $0.path == empty.path })
    }

    @Test func wrappedIOSApplicationIsReadWithoutInventingAMissingInfoPlist() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileSystemRoot(rootURL: folder)
        let outer = root.url(for: .applications).appendingPathComponent("Mobile.app")
        let inner = outer.appendingPathComponent("Wrapper/Mobile.app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.mobile"],
                                           format: .xml, options: 0)
            .write(to: inner.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: outer.appendingPathComponent("WrappedBundle").path,
                                                   withDestinationPath: "Wrapper/Mobile.app")
        let read = BundleSurfaceReader.read(at: outer, in: root, budget: .unlimited) { _ in
            BundleSurfaceReader.Signature(gap: "Unsigned code.")
        }
        #expect(read.1.completeness.isComplete)
        #expect(read.0.bundleIdentifiers.contains("org.example.mobile"))
        #expect(ApplicationBundle.isBundle(atPath: outer.path))
    }

    @Test func realDeadlineIsStillReportedAndSymlinkCyclesTerminate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("loop"),
            withDestinationURL: folder
        )
        let complete = ApplicationDirectoryScan.read(in: [folder], boundary: folder, budget: .unlimited)
        #expect(complete.completeness.isComplete)
        let expired = ApplicationDirectoryScan.read(in: [folder], boundary: folder, budget: ScanBudget(total: -1))
        #expect(!expired.completeness.timedOut.isEmpty)
    }

    @Test func sharedFrameworkCanProtectButCannotAuthorizeRemovalOutsideTheHost() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileSystemRoot(rootURL: folder)
        let app = root.url(for: .applications).appendingPathComponent("Editor.app")
        let shared = root.rootURL.appendingPathComponent("Library/Frameworks/Shared.framework")
        for (bundle, identifier) in [(app, "org.example.editor"), (shared, "org.example.shared")] {
            let info = bundle.appendingPathComponent("Contents/Info.plist")
            try FileManager.default.createDirectory(
                at: info.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier],
                                               format: .xml, options: 0).write(to: info)
        }
        let link = app.appendingPathComponent("Contents/Frameworks/Shared.framework")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared)
        let protective = BundleSurfaceReader.protectionClaims(at: app, in: root)
        #expect(protective.complete)
        #expect(protective.surface.bundleIdentifiers.contains("org.example.shared"))
        let removal = BundleSurfaceReader.read(at: app, in: root)
        #expect(!removal.0.bundleIdentifiers.contains("org.example.shared"))
        #expect(!removal.1.completeness.isComplete)
    }
}
