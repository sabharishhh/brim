import BrimCore
import BrimProtocol
@testable import BrimService
import Foundation
import Testing

struct CleanupPlanningIntegrationTests {
    @Test func incompleteVolumeReadsDoNotInventRecoveredSpace() {
        let volumes: Set = ["one", "two"]
        let before = Executor.sampleFreeSpace(on: volumes) { volume in
            if volume == "two" {
                throw NSError(domain: "Fixture", code: 1)
            }
            return 100
        }
        let after = Executor.sampleFreeSpace(on: volumes) { _ in 100 }
        #expect(before == nil)
        #expect(after == 200)
        #expect(BrimService.observedSpaceIncrease(before: before, after: after) == 0)
        #expect(Executor.sampleFreeSpace(on: volumes) { _ in 0 } == 0)
    }

    @Test func unknownCacheSettingsRemainRecoverable() async throws {
        let fixture = try CleanupPlanningFixture()
        defer { fixture.remove() }
        let target = try fixture.folder("Users/test/Library/Caches/LocalSettings")
        try Data("settings".utf8).write(to: target.appendingPathComponent("config.json"))
        let plan = try await fixture.service().plan(intent: fixture.intent(target))
        #expect(plan.steps.first?.effectiveDisposition == .trash)
    }

    @Test func changingProjectEvidenceInvalidatesPermanentRemoval() async throws {
        let fixture = try CleanupPlanningFixture()
        defer { fixture.remove() }
        let project = try fixture.folder("Users/test/Projects/Sample")
        let marker = project.appendingPathComponent("Cargo.toml")
        try Data("[package]".utf8).write(to: marker)
        let target = try fixture.folder("Users/test/Projects/Sample/target")
        try Data("output".utf8).write(to: target.appendingPathComponent("build.bin"))
        let service = fixture.service()
        let plan = try await service.plan(intent: fixture.intent(target))
        #expect(plan.steps.first?.effectiveDisposition == .delete)
        let receipt = try await service.requestApproval(planId: plan.planId, requesterIdentity: "user")
        let token = try await service.grantApproval(for: receipt)
        try FileManager.default.removeItem(at: marker)
        await #expect(throws: BrimService.ApplyError.self) {
            try await service.apply(planId: plan.planId, token: token)
        }
        #expect(FileManager.default.fileExists(atPath: target.path))
        let journal = fixture.base.appendingPathComponent("Journal/\(plan.planId.uuidString).journal")
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    @Test func statefulAndToolManagedTargetsCannotUseDirectRemoval() async throws {
        let fixture = try CleanupPlanningFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        for path in ["Users/test/Library/Developer/Xcode/Archives", "Users/test/Library/Caches/Homebrew"] {
            let target = try fixture.folder(path)
            let plan = try await service.plan(intent: fixture.intent(target))
            #expect(plan.steps.isEmpty)
            #expect(plan.excludedItems.first?.canBeTickedByHand != true)
        }
    }

    @Test func environmentEvidenceOverridesCacheAndCompletedDownloadClassification() async throws {
        let fixture = try CleanupPlanningFixture()
        defer { fixture.remove() }
        let cache = try fixture.folder("Users/test/Library/Developer/Xcode/DerivedData")
        try Data("home = /usr/bin".utf8).write(to: cache.appendingPathComponent("pyvenv.cfg"))
        let service = fixture.service()
        let cachePlan = try await service.plan(intent: fixture.intent(cache))
        #expect(cachePlan.steps.isEmpty)
        #expect(cachePlan.excludedItems.first?.canBeTickedByHand != true)
        let downloads = try fixture.folder("Users/test/Library/Caches/Homebrew/downloads")
        try Data("home = /usr/bin".utf8).write(to: downloads.appendingPathComponent("pyvenv.cfg"))
        let completed = downloads.appendingPathComponent(String(repeating: "a", count: 64) + "--package.tar.gz")
        try Data("download".utf8).write(to: completed)
        let downloadPlan = try await service.planHomebrewDownloads(
            cachePath: downloads.deletingLastPathComponent(), excluding: []
        )
        #expect(downloadPlan.steps.isEmpty)
        #expect(downloadPlan.excludedItems.first?.canBeTickedByHand != true)
    }

    @Test func excludedFoldersProtectBothTheirContentsAndTheirRemovalParents() async throws {
        let fixture = try CleanupPlanningFixture()
        defer { fixture.remove() }
        let parent = try fixture.folder("Users/test/Projects/Output")
        let excluded = try fixture.folder("Users/test/Projects/Output/Keep")
        let child = try fixture.folder("Users/test/Projects/Output/Keep/Child")
        for target in [parent, excluded, child] {
            let intent = PlanIntent(
                type: .uninstall,
                subjectIdentity: Identity(bundleID: nil, name: "Output"),
                specificTarget: target,
                excludedFolders: [excluded]
            )
            await #expect(throws: BrimService.ApplyError.self) {
                _ = try await fixture.service().plan(intent: intent)
            }
        }
    }

    @Test func rootFolderExclusionBlocksDirectTargetsAndCompletedDownloads() async throws {
        let fixture = try CleanupPlanningFixture()
        defer { fixture.remove() }
        let target = try fixture.folder("Users/test/Projects/Output")
        let excluded = URL(fileURLWithPath: "/")
        let service = fixture.service()
        await #expect(throws: BrimService.ApplyError.self) {
            _ = try await service.plan(intent: PlanIntent(
                type: .uninstall, subjectIdentity: Identity(bundleID: nil, name: "Output"),
                specificTarget: target, excludedFolders: [excluded]
            ))
        }
        let downloads = try fixture.folder("Users/test/Library/Caches/Homebrew/downloads")
        let file = downloads.appendingPathComponent(String(repeating: "a", count: 64) + "--archive.tar.gz")
        try Data("download".utf8).write(to: file)
        await #expect(throws: (any Error).self) {
            _ = try await service.planHomebrewDownloads(
                cachePath: downloads.deletingLastPathComponent(), excluding: [excluded]
            )
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func completedDownloadsUseTheNormalTrashApprovalAndUndoRoute() async throws {
        let fixture = try CleanupPlanningFixture()
        defer { fixture.remove() }
        let downloads = try fixture.folder("Users/test/Library/Caches/Homebrew/downloads")
        let name = String(repeating: "a", count: 64) + "--archive.tar.gz"
        let target = downloads.appendingPathComponent(name)
        try Data("download".utf8).write(to: target)
        let unknown = downloads.appendingPathComponent("personal-note.txt")
        try Data("keep".utf8).write(to: unknown)
        let service = fixture.service()
        let plan = try await service.planHomebrewDownloads(
            cachePath: downloads.deletingLastPathComponent(),
            excluding: []
        )
        #expect(plan.steps.map(\.target) == [target.path])
        #expect(plan.steps.first?.effectiveDisposition == .trash)
        let receipt = try await service.requestApproval(
            planId: plan.planId,
            requesterIdentity: plan.intent.requesterIdentity
        )
        let token = try await service.grantApproval(for: receipt)
        try await service.apply(planId: plan.planId, token: token)
        let result = try await service.verify(planId: plan.planId)
        #expect(result.success)
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        let journal = try await JournalStore(directoryURL: fixture.base.appendingPathComponent("Journal"))
            .load(planId: plan.planId)
        let trashed = try #require(journal?.stepTrashedURLs?.values.first)
        let testTrashRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        #expect(trashed.resolvingSymlinksInPath().path.hasPrefix(testTrashRoot + "/"))
        try await service.undo(planId: plan.planId)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func aDownloadThatBecomesActiveCannotUseThePreviousApproval() async throws {
        let fixture = try CleanupPlanningFixture()
        defer { fixture.remove() }
        let downloads = try fixture.folder("Users/test/Library/Caches/Homebrew/downloads")
        let name = String(repeating: "a", count: 64) + "--archive.tar.gz"
        let target = downloads.appendingPathComponent(name)
        try Data("download".utf8).write(to: target)
        let service = fixture.service()
        let plan = try await service.planHomebrewDownloads(
            cachePath: downloads.deletingLastPathComponent(),
            excluding: []
        )
        let receipt = try await service.requestApproval(
            planId: plan.planId,
            requesterIdentity: plan.intent.requesterIdentity
        )
        let token = try await service.grantApproval(for: receipt)
        try Data("active".utf8).write(to: downloads.appendingPathComponent(name + ".incomplete"))
        await #expect(throws: BrimService.ApplyError.self) {
            try await service.apply(planId: plan.planId, token: token)
        }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func packageRecordsAreBoundToTheSelectedAppPath() async throws {
        let fixture = try CleanupPlanningFixture()
        defer { fixture.remove() }
        let selected = try fixture.application("Recorded")
        let receipt = try fixture.cask("recorded", application: selected)
        let service = fixture.service()
        let identity = Identity(bundleID: "org.example.recorded", name: "Recorded", bundlePath: selected.path)
        let plan = try await service.plan(intent: PlanIntent(type: .uninstall, subjectIdentity: identity))
        #expect(plan.homebrewInstallation?.applicationPath == selected.path)
        let result = try await service.verify(planId: plan.planId)
        #expect(result.packageRecord?.state == .present)
        let approval = try await service.requestApproval(planId: plan.planId, requesterIdentity: "user")
        let token = try await service.grantApproval(for: approval)
        try FileManager.default.removeItem(at: receipt)
        await #expect(throws: BrimService.ApplyError.self) {
            try await service.apply(planId: plan.planId, token: token)
        }
        #expect(FileManager.default.fileExists(atPath: selected.path))
    }

    @Test func onlyExactMissingRecordedAppPathsAreOrphans() async throws {
        let fixture = try CleanupPlanningFixture()
        defer { fixture.remove() }
        let missing = fixture.base.appendingPathComponent("Applications/Recorded.app")
        _ = try fixture.cask("recorded", application: missing)
        _ = try fixture.application("AnotherCopy")
        #expect(await fixture.service().orphanedCaskNames() == ["recorded"])
        _ = try fixture.folder("Applications/Recorded.app")
        #expect(await fixture.service().orphanedCaskNames().isEmpty)
    }
}

private struct CleanupPlanningFixture {
    let base: URL
    var root: FileSystemRoot {
        FileSystemRoot(rootURL: base, userName: "test")
    }

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BrimPlanning-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func folder(_ path: String) throws -> URL {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func service() -> BrimService {
        BrimService(
            root: root,
            brimAppURL: base.appendingPathComponent("Brim.app"),
            planStoreDirectory: base.appendingPathComponent("Plans"),
            journalStoreDirectory: base.appendingPathComponent("Journal")
        )
    }

    func intent(_ target: URL) -> PlanIntent {
        PlanIntent(
            type: .uninstall,
            subjectIdentity: Identity(bundleID: nil, name: "Selected artifact"),
            specificTarget: target
        )
    }

    func application(_ name: String) throws -> URL {
        let app = try folder("Applications/\(name).app/Contents").deletingLastPathComponent()
        let plist = ["CFBundleIdentifier": "org.example.recorded", "CFBundleName": name, "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    func cask(_ token: String, application: URL) throws -> URL {
        let cask = try folder("opt/homebrew/Caskroom/\(token)")
        let metadata = try folder("opt/homebrew/Caskroom/\(token)/.metadata")
        let version = try folder("opt/homebrew/Caskroom/\(token)/1")
        let receipt = metadata.appendingPathComponent("INSTALL_RECEIPT.json")
        let values: [String: Any] = [
            "source": ["version": "1"],
            "uninstall_artifacts": [["app": [application.lastPathComponent]]]
        ]
        try JSONSerialization.data(withJSONObject: values).write(to: receipt)
        try FileManager.default.createSymbolicLink(
            at: version.appendingPathComponent(application.lastPathComponent),
            withDestinationURL: application
        )
        _ = cask
        return receipt
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
