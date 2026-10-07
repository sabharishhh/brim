import BrimCore
import BrimProtocol
import BrimUI
import Foundation
import Testing

/// Pages follow the Mac while Brim is open, through macOS's own events and
/// cheap checks, rather than waiting for Check Again.
@MainActor struct LivePagesTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("brim-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func app(_ name: String, in folder: URL) throws -> URL {
        let app = folder.appendingPathComponent(name + ".app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    @Test func `a change in a watched folder is reported`() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watching = Task {
            for await _ in FolderWatch.changes(in: [folder], latency: 0.05) {
                return true
            }
            return false
        }
        try await Task.sleep(for: .milliseconds(300))
        _ = try app("Arrived", in: folder)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            watching.cancel()
        }
        #expect(await watching.value)
        timeout.cancel()
    }

    /// Opening an app makes macOS note it on the bundle, which is an event
    /// in the Applications folder. Listing again for it would add a history
    /// snapshot every time an app was opened.
    @Test func `opening an app is not a change, an install or an update is`() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let demo = try app("Demo", in: folder)
        let before = ApplicationFolders.signature(of: [folder])
        _ = "opened".withCString { setxattr(demo.path, "com.apple.lastuseddate#PS", $0, strlen($0), 0, 0) }
        #expect(ApplicationFolders.signature(of: [folder]) == before)

        let later = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: later],
                                              ofItemAtPath: demo.appendingPathComponent("Contents/Info.plist").path)
        #expect(ApplicationFolders.signature(of: [folder]) != before)
        _ = try app("Second", in: folder)
        #expect(ApplicationFolders.signature(of: [folder]).count == 2)
    }

    /// A scan again must not undo what the person chose: an orphan they
    /// unticked stays unticked, and only something new is ticked for them.
    @Test func `scanning again keeps the person's choices`() async {
        let service = Shelf(leftovers: [orphan("Kept"), orphan("Other")])
        let model = LeftoversModel()
        await model.load(service: service)
        let kept = model.orphanedGroups.first { $0.displayName == "Kept" }
        #expect(kept != nil)
        if let kept {
            model.toggle(kept)
        }
        await service.set([orphan("Kept"), orphan("Other"), orphan("New")])
        model.markStale()
        await model.loadIfNeeded(service: service)
        let ticked = Set(model.selectedItems.map(\.url.lastPathComponent))
        #expect(ticked == ["Other", "New"])
    }

    /// An app that updated itself kept offering the update it had just
    /// installed until the next network check, hours later.
    @Test func `an app that updated itself leaves Updates at once`() async {
        let url = URL(fileURLWithPath: "/Applications/Demo.app")
        let update = AppUpdate(bundleID: "com.example.demo", name: "Demo", appURL: url, installedVersion: "1.0",
                               latestVersion: "1.1", origin: .sparkle(feed: "https://example.com/appcast.xml"),
                               route: .replace)
        let model = UpdatesModel()
        await model.load(service: Shelf(updates: [update]))
        #expect(model.count == 1)
        model.reconcile(with: [installed(url, version: "1.0")])
        #expect(model.count == 1)
        model.reconcile(with: [installed(url, version: "1.1")])
        #expect(model.count == 0)
    }

    private func orphan(_ name: String) -> Leftover {
        Leftover(url: URL(fileURLWithPath: "/fixture/" + name), size: 100, category: .orphaned,
                 potentialOwner: Identity(bundleID: "org.example." + name, name: name), evidence: "Fixture record")
    }

    private func installed(_ url: URL, version: String) -> InstalledApplication {
        InstalledApplication(identity: Identity(bundleID: "com.example.demo", name: "Demo", version: version),
                             url: url, bundleSizeBytes: 1, isSystemProtected: false)
    }
}

private actor Shelf: BrimServiceProtocol {
    private var items: [Leftover]
    private let updates: [AppUpdate]

    init(leftovers: [Leftover] = [], updates: [AppUpdate] = []) {
        items = leftovers
        self.updates = updates
    }

    func set(_ leftovers: [Leftover]) {
        items = leftovers
    }

    func leftovers() async throws -> [Leftover] {
        items
    }

    func checkForUpdates() async -> UpdateCheck {
        UpdateCheck(updates: updates, checked: updates.count, unchecked: [], checkedAt: Date())
    }

    func installedApplications() async throws -> [InstalledApplication] {
        []
    }

    func recoverableItems() async throws -> [RecoverableItem] {
        []
    }

    func history() async throws -> [Plan] {
        []
    }

    func inspect(identity _: Identity) async throws -> Footprint {
        throw Unused.unused
    }

    func plan(intent _: PlanIntent) async throws -> Plan {
        throw Unused.unused
    }

    func requestApproval(planId _: UUID, requesterIdentity _: String) async throws -> ApprovalRequestReceipt {
        throw Unused.unused
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {
        throw Unused.unused
    }

    func verify(planId _: UUID) async throws -> VerificationResult {
        throw Unused.unused
    }

    func undo(planId _: UUID) async throws {
        throw Unused.unused
    }
}

private enum Unused: Error { case unused }
