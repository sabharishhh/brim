import BrimCore
import BrimIndex
@testable import BrimService
import Foundation
import Testing

struct RecentInstallDateTests {
    @Test func aRecordedReinstallReceivesItsNewAppearanceDateEvenWhenAddedAtIsOld() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = service(in: directory)
        let index = try Index(dbManager: DatabaseManager(databaseURL: directory.appendingPathComponent("brim.sqlite")))
        let old = Date().addingTimeInterval(-10 * 86400)
        let anchor = app("Anchor")
        let returned = app("Returned", addedAt: old)
        _ = try await index.recordInstalled([observation(anchor), observation(returned)], at: old)
        _ = try await index.recordInstalled([observation(anchor)], at: old.addingTimeInterval(86400))
        await service.useApplicationInventory(reader: { [anchor, returned] }, recovery: { [:] })
        let installed = try await service.installedApplications()
        let expected = try await index.appearanceWindows()[#require(returned.identity.bundleID)]?.seen
        #expect(expected != nil)
        #expect(installed.first { $0.id == returned.id }?.installedAt == expected)
        #expect(installed.first { $0.id == anchor.id }?.installedAt == nil)
    }

    /// Spotlight rewrites date added during an update. That cannot undo the
    /// earlier evidence that a newly discovered bundle was already installed.
    @Test func anUpdateCannotTurnANewlyDiscoveredOldAppIntoARecentInstallation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = service(in: directory)
        let index = try Index(dbManager: DatabaseManager(databaseURL: directory.appendingPathComponent("brim.sqlite")))
        let old = Date().addingTimeInterval(-10 * 86400)
        let anchor = app("Anchor")
        _ = try await index.recordInstalled([observation(anchor)], at: old)
        let discovered = app("Discovered", addedAt: old.addingTimeInterval(-86400))
        await service.useApplicationInventory(reader: { [anchor, discovered] }, recovery: { [:] })
        let first = try await service.installedApplications()
        #expect(first.first { $0.id == discovered.id }?.installedAt == nil)
        let updated = app("Discovered", version: "2", addedAt: Date())
        await service.useApplicationInventory(reader: { [anchor, updated] }, recovery: { [:] })
        let later = try await service.installedApplications()
        #expect(later.first { $0.id == updated.id }?.installedAt == nil)
        let history = await service.whatChanged()
        #expect(history.changes.allSatisfy { $0.kind != .appeared })
        #expect(history.changes.contains { $0.kind == .updated(from: "1", to: "2") })
    }

    private func service(in directory: URL) -> BrimService {
        BrimService(root: FileSystemRoot(rootURL: directory.appendingPathComponent("Root")),
                    brimAppURL: directory.appendingPathComponent("Brim.app"),
                    planStoreDirectory: directory.appendingPathComponent("Plans"),
                    journalStoreDirectory: directory.appendingPathComponent("Journals"))
    }

    private func app(_ name: String, version: String = "1", addedAt: Date? = nil) -> InstalledApplication {
        InstalledApplication(identity: Identity(bundleID: "org.example." + name, name: name, version: version),
                             url: URL(fileURLWithPath: "/fixture/\(name).app"),
                             bundleSizeBytes: 100, isSystemProtected: false, addedAt: addedAt)
    }

    private func observation(_ application: InstalledApplication) -> InstallObservation {
        InstallObservation(bundleID: application.identity.bundleID!, name: application.name,
                           version: application.version, bundlePath: application.url.path,
                           sizeBytes: application.bundleSizeBytes, addedAt: application.addedAt)
    }
}
