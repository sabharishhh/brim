import BrimCore
import BrimOps
@testable import BrimService
import Foundation
import Testing

struct DockShortcutTests {
    @Test func unreadableDockDoesNotBlockPlanningTheApplicationRemoval() async throws {
        let fixture = try DockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        try fixture.write(tiles: [])
        try Data("invalid preferences".utf8).write(to: fixture.file)
        let app = fixture.folder.appendingPathComponent("Applications/Editor.app")
        let info = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "org.example.editor"], format: .xml, options: 0
        ).write(to: info)
        let service = BrimService(
            root: fixture.root, brimAppURL: fixture.folder.appendingPathComponent("Brim.app"),
            planStoreDirectory: fixture.folder.appendingPathComponent("Plans"),
            journalStoreDirectory: fixture.folder.appendingPathComponent("Journal")
        )
        let plan = try await service.plan(intent: PlanIntent(
            type: .uninstall,
            subjectIdentity: Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: app.path),
            specificTarget: app
        ))
        #expect(plan.dockShortcutReadError != nil)
        let removals = plan.steps.filter { $0.kind == .trashPath }.map {
            URL(fileURLWithPath: $0.target).resolvingSymlinksInPath()
        }
        #expect(removals.contains(app.resolvingSymlinksInPath()))
        #expect(!DockShortcutVerification(plan: plan, root: fixture.root).isComplete)
    }

    @Test func removesOnlyTheReviewedPathAndKeepsOtherDockPreferences() async throws {
        let fixture = try DockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let removed = fixture.folder.appendingPathComponent("Applications/My Editor.app").path
        let other = fixture.folder.appendingPathComponent("Elsewhere/My Editor.app").path
        try fixture.write(tiles: [fixture.tile(removed), fixture.tile(other), ["tile-type": "spacer-tile"]])
        let client = DockShortcuts.Client(root: fixture.root)
        try await client.remove(removed)
        #expect(try DockShortcuts.pinnedPaths(in: fixture.root) == [other])
        let saved = try #require(NSDictionary(contentsOf: fixture.file))
        #expect(saved["orientation"] as? String == "left")
        #expect((saved["persistent-apps"] as? [[String: Any]])?.count == 2)
        try await client.remove(removed)
        #expect(try DockShortcuts.pinnedPaths(in: fixture.root) == [other])
    }

    @Test func keepsThePinWhenTheApplicationWasNotRemoved() async throws {
        let fixture = try DockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let app = fixture.folder.appendingPathComponent("Applications/Editor.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try fixture.write(tiles: [fixture.tile(app.path)])
        await #expect(throws: (any Error).self) { try await DockShortcuts.Client(root: fixture.root).remove(app.path) }
        #expect(try DockShortcuts.pinnedPaths(in: fixture.root) == [app.path])
    }

    @Test func plansThePinOnlyWithItsExactRemovedBundle() throws {
        let fixture = try DockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let app = fixture.folder.appendingPathComponent("Applications/Editor.app")
        let copy = fixture.folder.appendingPathComponent("Other/Editor.app")
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: app.path)
        let item = EvaluatedItem(footprintItem: FootprintItem(evidence: Evidence(
            url: app, tier: .A, mechanism: "AppBundleSource", humanSentence: "The app"
        ), sizeBytes: 0, capability: .ok), selection: .selected, costOfError: .medium)
        let plan = Planner().createPlan(from: EvaluatedFootprint(identity: identity, items: [item]),
                                        intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
                                        engineVersion: "test",
                                        dockPinnedPaths: [app.path, copy.path])
        #expect(plan.steps.filter { $0.kind == .removeDockShortcut }.map(\.target) == [app.path])
        #expect(plan.executionOrderedSteps.last?.kind == .removeDockShortcut)
        #expect(!StepKind.removeDockShortcut.targetIsPath)
        #expect(!StepKind.removeDockShortcut.destroysWithoutRecovery)
    }

    @Test func rejectsCorruptDockPreferencesWithoutReplacingThem() async throws {
        let fixture = try DockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        try fixture.write(tiles: [])
        let corrupt = Data("not a property list".utf8)
        try corrupt.write(to: fixture.file)
        await #expect(throws: (any Error).self) {
            try await DockShortcuts.Client(root: fixture.root)
                .remove(fixture.folder.appendingPathComponent("Gone.app").path)
        }
        #expect(try Data(contentsOf: fixture.file) == corrupt)
    }

    @Test func executorDoesNotUnpinWithoutASuccessfulRemovalStep() async throws {
        let fixture = try DockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let path = fixture.folder.appendingPathComponent("Gone.app").path
        try fixture.write(tiles: [fixture.tile(path)])
        let step = Step(index: 0, kind: .removeDockShortcut, target: path, targetFingerprint: nil,
                        tier: .B, evidence: "Dock shortcut", expectedBytes: 0, capability: .ok, reversible: false,
                        costOfError: .low, executionPhase: .registration, disposition: .delete)
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
                        intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(name: "Gone")), steps: [step],
                        excludedItems: [], expectedTotalBytes: 0)
        let executor = Executor(
            journalStore: JournalStore(directoryURL: fixture.folder.appendingPathComponent("Journal")),
            dockShortcuts: .init(root: fixture.root)
        )
        let journal = try await executor.execute(plan: plan)
        #expect(journal.stepOutcomes[0] != "ok")
        #expect(try DockShortcuts.pinnedPaths(in: fixture.root) == [path])
    }

    @Test func executorUnpinsAfterTheApplicationIsConfirmedGone() async throws {
        let fixture = try DockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let path = fixture.folder.appendingPathComponent("Gone.app").path
        try fixture.write(tiles: [fixture.tile(path)])
        let removal = Step(index: 0, kind: .trashPath, target: path, targetFingerprint: nil,
                           tier: .A, evidence: "The app", expectedBytes: 0, capability: .ok, reversible: true,
                           costOfError: .medium, executionPhase: .appBundle, disposition: .trash)
        let pin = Step(index: 1, kind: .removeDockShortcut, target: path, targetFingerprint: nil,
                       tier: .B, evidence: "Dock shortcut", expectedBytes: 0, capability: .ok, reversible: false,
                       costOfError: .low, executionPhase: .registration, disposition: .delete)
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
                        intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(name: "Gone")), steps: [
                            removal,
                            pin
                        ],
                        excludedItems: [], expectedTotalBytes: 0)
        let executor = Executor(
            journalStore: JournalStore(directoryURL: fixture.folder.appendingPathComponent("Journal")),
            dockShortcuts: .init(root: fixture.root)
        )
        let journal = try await executor.execute(plan: plan)
        #expect(journal.stepOutcomes[0] == "already_gone")
        #expect(journal.stepOutcomes[1] == "ok")
        #expect(try DockShortcuts.pinnedPaths(in: fixture.root).isEmpty)
    }
}

private struct DockFixture {
    let folder: URL
    var root: FileSystemRoot {
        FileSystemRoot(rootURL: folder, userName: "tester")
    }

    var file: URL {
        root.url(for: .userLibrary).appendingPathComponent("Preferences/com.apple.dock.plist")
    }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func tile(_ path: String) -> [String: Any] {
        ["tile-type": "file-tile", "tile-data": ["file-label": "Editor",
                                                 "file-data": [
                                                     "_CFURLString": URL(fileURLWithPath: path).absoluteString,
                                                     "_CFURLStringType": 15
                                                 ]]]
    }

    func write(tiles: [[String: Any]]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["persistent-apps": tiles, "orientation": "left"],
                                           format: .binary, options: 0).write(to: file)
    }
}
