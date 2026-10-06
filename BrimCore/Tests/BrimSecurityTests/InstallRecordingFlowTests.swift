import BrimCore
import BrimProtocol
import BrimScan
@testable import BrimService
import Foundation
import Testing

/// A recording from start to use: the first snapshot survives a new
/// service (Brim quitting while something installs), what is kept becomes
/// removal evidence, and once the app is gone it is offered in Remnants.
struct InstallRecordingFlowTests {
    @Test func `a kept recording reaches the removal and Remnants`() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrimRecording-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = FileSystemRoot(rootURL: base, userName: "test")
        func service() -> BrimService {
            BrimService(root: root, brimAppURL: base.appendingPathComponent("Brim.app"),
                        planStoreDirectory: base.appendingPathComponent("State/Plans"),
                        journalStoreDirectory: base.appendingPathComponent("State/Journal"))
        }
        let manager = FileManager.default
        for domain in [FileSystemRoot.Domain.applications, .userApplicationSupport, .userPreferences] {
            try manager.createDirectory(at: root.url(for: domain), withIntermediateDirectories: true)
        }

        let began = try await service().beginInstallRecording()
        // A new service, as after Brim quits and opens again.
        #expect(await service().activeInstallRecording() == began)

        // The install: an app, and a folder whose name says nothing of it.
        let bundle = root.url(for: .applications).appendingPathComponent("Demo.app")
        try manager.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.vendorco.demo", "CFBundleName": "Demo", "CFBundleShortVersionString": "1.0"
        ], format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let engine = root.url(for: .userApplicationSupport).appendingPathComponent("RenderEngine")
        try manager.createDirectory(at: engine, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: engine.appendingPathComponent("cache.bin"))
        let preferences = root.url(for: .userPreferences).appendingPathComponent("com.vendorco.demo.plist")
        try PropertyListSerialization.data(fromPropertyList: ["A": 1], format: .binary, options: 0)
            .write(to: preferences)

        let brim = service()
        let result = try await brim.finishInstallRecording()
        #expect(result.apps.map(\.bundleID) == ["com.vendorco.demo"])
        #expect(result.linked.map(\.path) == [preferences.path])
        #expect(result.unclaimed.map(\.path) == [engine.path])
        // The person keeps the folder only they knew came with it.
        let kept = InstallRecording(startedAt: result.startedAt, endedAt: result.endedAt, apps: result.apps,
                                    items: result.linked + result.unclaimed)
        try await brim.keepInstallRecording(kept)
        #expect(await brim.activeInstallRecording() == nil)
        #expect(await brim.installRecordings().count == 1)

        let identity = await IdentityResolver(root: root).resolve(bundleURL: bundle)
        let footprint = try await service().inspect(identity: identity)
        let recorded = footprint.items.first { $0.evidence.url.path == engine.path }
        #expect(recorded?.evidence.tier == .B)
        #expect(recorded?.evidence.humanSentence.hasPrefix("Appeared when you installed Demo") == true)

        // Dragged to the Trash: what the recording kept is Demo's remnant.
        try manager.removeItem(at: bundle)
        let remnants = try await service().leftovers()
        let remnant = remnants.first { $0.url.path == engine.path }
        #expect(remnant?.category == .orphaned)
        #expect(remnant?.potentialOwner?.name == "Demo")
    }

    @Test func `finishing without a recording says so`() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("BrimRecording-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let brim = BrimService(root: FileSystemRoot(rootURL: base, userName: "test"),
                               brimAppURL: base.appendingPathComponent("Brim.app"),
                               planStoreDirectory: base.appendingPathComponent("Plans"),
                               journalStoreDirectory: base.appendingPathComponent("Journal"))
        await #expect(throws: BrimService.RecordingError.self) { try await brim.finishInstallRecording() }
    }
}
