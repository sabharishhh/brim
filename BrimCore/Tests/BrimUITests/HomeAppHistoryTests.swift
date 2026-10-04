import BrimCore
@testable import BrimUI
import Foundation
import Testing

@MainActor struct HomeAppHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86400

    @Test func recentlyInstalledUsesFiveDaysAndIncludesEveryCurrentRecentApp() {
        let model = ApplicationsModel()
        let recent = (0 ..< 7).map { app("Recent\($0)", installedAt: now - Double($0) * day / 2) }
        var embedded = app("Embedded", installedAt: now)
        embedded.enclosingApp = "Host"
        model.acceptForTesting(recent + [app("Boundary", installedAt: now - 5 * day),
                                         app("Old", installedAt: now - 5 * day - 1), app("Unknown"),
                                         app("Future", installedAt: now + 1), embedded])
        #expect(model.recentlyInstalled(now: now).map(\.name) == recent.map(\.name) + ["Boundary"])
    }

    @Test func removingAnAppDropsItsRecentRowAndItsReturnUsesTheNewDate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("Returned.app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ApplicationsModel()
        let installed = app("Returned", installedAt: now - 4 * day, url: url)
        model.acceptForTesting([installed])
        #expect(model.recentlyInstalled(now: now).count == 1)
        #expect(!model.forgetIfRemoved(installed))
        try FileManager.default.removeItem(at: url)
        #expect(model.forgetIfRemoved(installed))
        #expect(model.recentlyInstalled(now: now).isEmpty)
        model.acceptForTesting([app("Returned", installedAt: now, url: url)])
        #expect(model.recentlyInstalled(now: now).first?.installedAt == now)
    }

    @Test func weeklyChangesExcludeOldFutureSizeAndUnknownVersionEvents() {
        let included = [change(.appeared, at: now - 7 * day), change(.disappeared, at: now - day),
                        change(.updated(from: "1", to: "2"), at: now)]
        let excluded = [change(.appeared, at: now - 7 * day - 1), change(.appeared, at: now + 1),
                        change(.grew(by: 100_000_000), at: now), change(.shrank(by: 100_000_000), at: now),
                        change(.updated(from: nil, to: "1"), at: now)]
        let history = InstallHistory(changes: included + excluded, snapshots: 5)
        #expect(HomeStatus.changes(history, now: now) == included)
        #expect(HomeStatus.changes(InstallHistory(changes: included, snapshots: 1), now: now).isEmpty)
    }

    @Test func olderEncodedChangesDecodeWithoutASnapshotIdentifier() throws {
        let original = change(.appeared, at: now)
        let data = try JSONEncoder().encode(original)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["snapshotID"] == nil)
        let decoded = try JSONDecoder().decode(InstallChange.self, from: data)
        #expect(decoded == original)
        #expect(decoded.id == original.id)
    }

    private func app(_ name: String, installedAt: Date? = nil, url: URL? = nil) -> InstalledApplication {
        InstalledApplication(identity: Identity(bundleID: "org.example." + name, name: name),
                             url: url ?? URL(fileURLWithPath: "/fixture/\(name).app"),
                             bundleSizeBytes: 1, isSystemProtected: false, installedAt: installedAt)
    }

    private func change(_ kind: InstallChange.Kind, at date: Date) -> InstallChange {
        InstallChange(kind: kind, bundleID: "org.example.fixture", name: "Fixture", since: date - day, until: date)
    }
}
