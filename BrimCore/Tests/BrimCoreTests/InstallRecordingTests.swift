@testable import BrimCore
@testable import BrimScan
import Foundation
import Testing

// swiftformat:disable wrapMultilineStatementBraces
/// Recording an install: two snapshots and a subtraction, attributed by
/// name, developer or registration, never by timing alone.
struct InstallRecordingTests {
    private let app = "/Applications/Demo.app"

    private func snapshot(_ paths: [String], apps: [String: InstallSnapshot.AppMark] = [:],
                          background: [String: InstallSnapshot.BackgroundMark] = [:],
                          at time: TimeInterval = 0) -> InstallSnapshot {
        InstallSnapshot(takenAt: Date(timeIntervalSince1970: time), paths: Set(paths), apps: apps,
                        backgroundItems: background, unreadable: [])
    }

    private var demo: InstallSnapshot.AppMark {
        .init(identifier: "com.vendorco.demo", version: "1.0", names: ["Demo"])
    }

    @Test func `what appeared is attributed by name, developer and registration`() {
        let support = "/Users/me/Library/Application Support"
        let before = snapshot([support + "/Other"])
        let after = snapshot([
            support + "/Other", app, support + "/Demo", support + "/Demo/cache", support + "/VendorCo",
            "/Users/me/Library/Preferences/com.vendorco.demo.plist",
            "/Users/me/Library/Preferences/com.vendorco.updater.plist",
            "/Users/me/Library/Caches/com.otherco.notes", "/Users/me/.democonfig", "/Users/me/.mystery"
        ], apps: [app: demo], background: [
            "uuid-1": .init(label: "Demo Helper", bundleIdentifier: "com.vendorco.demo.helper", path: nil),
            "uuid-2": .init(label: "Someone", bundleIdentifier: "com.someone.agent", path: nil)
        ], at: 60)
        let notes = InstallClaimant(name: "Notes Plus", bundleID: "com.otherco.notes", names: ["Notes Plus"])
        let result = InstallRecordingDiff.result(before: before, after: after, installed: [notes])

        #expect(result.apps.map(\.name) == ["Demo"])
        #expect(result.apps.first?.wasUpdated == false)
        #expect(result.linked.map(\.path) == [
            support + "/Demo", support + "/VendorCo", "/Users/me/Library/Preferences/com.vendorco.demo.plist",
            "/Users/me/Library/Preferences/com.vendorco.updater.plist", "Demo Helper"
        ])
        #expect(result.linked.first?.why == "Named for Demo")
        #expect(result.linked[1].why == "From the developer of Demo")
        #expect(result.linked[3].why == "From the developer of Demo")
        #expect(result.linked.last?.isRegistration == true)
        #expect(result.otherApps == ["Notes Plus": 1])
        // Timing alone links nothing: these are shown, not kept.
        #expect(Set(result.unclaimed.map(\.path)) == ["/Users/me/.democonfig", "/Users/me/.mystery", "Someone"])
    }

    @Test func `an app updated while recording does not take what a new one made`() {
        let other = "/Applications/Other.app"
        let before = snapshot([other], apps: [other: .init(identifier: "com.vendorco.other", version: "1",
                                                           names: ["Other"])])
        let after = snapshot([other, app, "/Library/Application Support/com.vendorco.shared"], apps: [
            other: .init(identifier: "com.vendorco.other", version: "2", names: ["Other"]), app: demo
        ])
        let result = InstallRecordingDiff.result(before: before, after: after, installed: [])
        #expect(result.apps.map(\.name) == ["Demo", "Other"])
        #expect(result.apps.last?.wasUpdated == true)
        #expect(result.linked.first?.app == app)
    }

    @Test func `a code host's namespace is nobody's developer`() {
        #expect(InstallRecordingDiff.vendor(of: "io.github.someone.tool") == nil)
        #expect(InstallRecordingDiff.vendor(of: "com.apple.Safari") == nil)
        #expect(InstallRecordingDiff.vendor(of: "com.vendorco.demo") == "com.vendorco")
        #expect(InstallRecordingDiff.matchesName("com.vendorco.demo.savedState", of: "com.vendorco.demo", names: []))
        #expect(InstallRecordingDiff.matchesName("com.vendorco.demonstration", of: "com.vendorco.demo",
                                                 names: []) == false)
        #expect(InstallRecordingDiff.matchesName("Demo", of: nil, names: ["De"]) == false)
    }

    // MARK: - Snapshots of a real tree

    @Test func `a snapshot lists the inventory and nothing of the person's own`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("brim-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileSystemRoot(rootURL: folder, userName: "tester")
        let manager = FileManager.default
        try manager.createDirectory(at: root.url(for: .userApplicationSupport), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.url(for: .applications), withIntermediateDirectories: true)
        let home = root.url(for: .userHomeDotFolders)
        let reader = InstallSnapshotReader(root: root, own: ["com.sabharishhh.brim", "Brim"],
                                           backgroundItems: { [] })
        let before = reader.take(at: Date(timeIntervalSince1970: 0))

        let bundle = root.url(for: .applications).appendingPathComponent("Demo.app/Contents")
        try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.vendorco.demo", "CFBundleShortVersionString": "1.0"
        ], format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        let data = root.url(for: .userApplicationSupport).appendingPathComponent("VendorCo/Demo")
        try manager.createDirectory(at: data, withIntermediateDirectories: true)
        try manager.createDirectory(at: home.appendingPathComponent(".demo"), withIntermediateDirectories: true)
        try manager.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.url(for: .userCaches).appendingPathComponent("com.apple.Something"),
                                    withIntermediateDirectories: true)
        // Brim's own, written because Brim is recording.
        let brimData = root.url(for: .userApplicationSupport).appendingPathComponent("Brim/Recordings")
        try manager.createDirectory(at: brimData, withIntermediateDirectories: true)
        try manager.createDirectory(at: root.url(for: .userCaches).appendingPathComponent("com.sabharishhh.brim"),
                                    withIntermediateDirectories: true)
        let after = reader.take(at: Date(timeIntervalSince1970: 60))

        let result = InstallRecordingDiff.result(before: before, after: after, installed: [])
        #expect(result.apps.first?.bundleID == "com.vendorco.demo")
        let linked = Set(result.linked.map(\.path))
        // The developer's folder is new, so all of it came with the install.
        #expect(linked.contains(data.deletingLastPathComponent().path))
        #expect(linked.contains(home.appendingPathComponent(".demo").path))
        let everything = Set(result.linked.map(\.path) + result.unclaimed.map(\.path))
        #expect(!everything.contains(home.appendingPathComponent("Documents").path))
        #expect(!everything.contains { $0.contains("com.apple.Something") })
        let ownNames: Set = ["Brim", "com.sabharishhh.brim"]
        #expect(!everything.contains { ownNames.contains(($0 as NSString).lastPathComponent) })
    }

    // MARK: - Evidence and Remnants

    @Test func `a kept recording is Tier B evidence for what is still there`() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("brim-rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = folder.appendingPathComponent("vendor-data")
        let gone = folder.appendingPathComponent("already-gone")
        let suiteMate = folder.appendingPathComponent("other-app-data")
        for url in [kept, suiteMate] {
            try Data("x".utf8).write(to: url)
        }
        let recording = InstallRecording(
            startedAt: Date(), endedAt: Date(timeIntervalSince1970: 1_790_000_000),
            apps: [
                RecordedApp(name: "Demo", bundleID: "com.vendorco.demo", path: app, version: "1",
                            wasUpdated: false, names: ["Demo"]),
                RecordedApp(name: "Other", bundleID: "com.vendorco.other", path: "/Applications/Other.app",
                            version: "1", wasUpdated: false, names: ["Other"])
            ],
            items: [
                RecordedItem(path: kept.path, why: "Appeared while recording", app: nil),
                RecordedItem(path: gone.path, why: "Named for Demo", app: app),
                RecordedItem(path: suiteMate.path, why: "Named for Other", app: "/Applications/Other.app"),
                RecordedItem(path: "Demo Helper", why: "Registered", app: app, isRegistration: true)
            ]
        )
        let source = InstallRecordingSource(recordings: { [recording] })
        let found = try await source.evidence(for: Identity(bundleID: "com.vendorco.demo", name: "Demo"),
                                              in: FileSystemRoot(rootURL: folder))
        #expect(found.map(\.url.path) == [kept.path])
        #expect(found.first?.tier == .B)
        #expect(found.first?.humanSentence.hasPrefix("Appeared when you installed Demo on") == true)

        // Once Demo is gone, what it kept is offered in Remnants, under it.
        let remnants = InstallRecordingSource.remnants([recording], installed: ["com.vendorco.other"], listed: [],
                                                       inUseWithin: nil)
        #expect(remnants.map(\.url.path) == [kept.path])
        #expect(remnants.first?.category == .orphaned)
        #expect(remnants.first?.potentialOwner?.name == "Demo")
        #expect(InstallRecordingSource.remnants([recording], installed: ["com.vendorco.demo", "com.vendorco.other"],
                                                listed: [], inUseWithin: nil).isEmpty)
        #expect(InstallRecordingSource.remnants([recording], installed: ["com.vendorco.other"], listed: [kept.path],
                                                inUseWithin: nil).isEmpty)
        // Linked by timing alone and written just now: something alive has it.
        #expect(InstallRecordingSource.remnants([recording], installed: ["com.vendorco.other"], listed: [])
            .isEmpty)
    }
}
