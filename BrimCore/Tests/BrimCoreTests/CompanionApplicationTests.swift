@testable import BrimCore
@testable import BrimScan
import Foundation
import Testing

struct CompanionApplicationTests {
    /// A URL handler whose npm executable was removed must not veto an app's
    /// data as though it were still a runnable installation.
    @Test func missingExecutableDoesNotProtectDataButAnExistingOneDoes() async throws {
        let fixture = try CompanionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let missing = fixture.folder.appendingPathComponent("Removed/runtime")
        let wrapper = try fixture.wrapper("Editor URL Handler", target: missing)
        let identity = Identity(bundleID: "org.example.editor", name: "Editor")
        let support = fixture.root.url(for: .userApplicationSupport).appendingPathComponent("Editor")
        let item = EvaluatedItem(footprintItem: FootprintItem(
            evidence: Evidence(url: support, tier: .B, mechanism: "Test", humanSentence: "Identifier match"),
            sizeBytes: 0, capability: .ok
        ), selection: .selected, costOfError: .medium)
        let engine = TierSVetoEngine(root: fixture.root)

        #expect(ApplicationBundle.hasMissingLinkedExecutable(wrapper, in: fixture.root))
        let removed = await engine.applyVeto(to: EvaluatedFootprint(identity: identity, items: [item]))
        #expect(removed.items.first?.selection == .selected)

        try FileManager.default.createDirectory(
            at: missing.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: missing)
        #expect(!ApplicationBundle.hasMissingLinkedExecutable(wrapper, in: fixture.root))
        let installed = await engine.applyVeto(to: EvaluatedFootprint(identity: identity, items: [item]))
        guard case .excluded = installed.items.first?.selection else {
            Issue.record("A live wrapper must continue protecting data named for its executable.")
            return
        }
    }

    @Test func companionAndItsDataArePlannedWithTheHostWithoutASharedNameOrSignature() async throws {
        let fixture = try CompanionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let host = try fixture.bundle("Editor", identifier: "org.example.editor")
        let runtime = host.appendingPathComponent("Contents/MacOS/runtime")
        try FileManager.default.createDirectory(
            at: runtime.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: runtime)
        let wrapper = try fixture.wrapper("Deep Link Launcher", target: runtime)
        let cache = fixture.root.url(for: .userCaches).appendingPathComponent("org.example.launcher")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let unrelated = try fixture.wrapper(
            "Other Launcher",
            target: fixture.folder.appendingPathComponent("Other/runtime")
        )
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: host.path)
        let projector = FootprintProjector(engine: EvidenceEngine(sources: [
            AppBundleSource(), CompanionApplicationSource(), LocationInventorySource()
        ]))
        let footprint = try await projector.project(identity: identity, in: fixture.root)
        let evaluated = await SafetyEngine(
            safetyChecker: SafetyChecker(
                root: fixture.root,
                brimAppURL: fixture.folder.appendingPathComponent("Brim.app")
            ),
            vetoEngine: TierSVetoEngine(root: fixture.root)
        ).evaluate(footprint: footprint)
        let plan = Planner().createPlan(from: evaluated,
                                        intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
                                        engineVersion: "test")
        let paths = Set(plan.steps.filter { $0.kind == .trashPath }.map {
            URL(fileURLWithPath: $0.target).resolvingSymlinksInPath().path
        })
        #expect(paths.isSuperset(of: [host, wrapper, cache].map { $0.resolvingSymlinksInPath().path }))
        #expect(!paths.contains(unrelated.resolvingSymlinksInPath().path))
        #expect(plan.steps.contains { $0.kind == .unregisterLaunchServices
                && URL(fileURLWithPath: $0.target).resolvingSymlinksInPath() == wrapper.resolvingSymlinksInPath()
        })
    }

    @Test func harmlessNameMatchesAreSelectedOnlyAfterACompleteInventorySearch() async throws {
        let fixture = try CompanionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let identity = Identity(bundleID: "org.example.editor", name: "Editor")
        let paths = ["Library/Caches/Editor-extension", "Library/Logs/DiagnosticReports/Editor_2026-10-27.ips"]
        let items = paths.map { path in
            FootprintItem(evidence: Evidence(url: fixture.root.url(for: .userLibrary).deletingLastPathComponent()
                              .appendingPathComponent(path), tier: .C, mechanism: "LocationInventorySource",
                humanSentence: "Name match"),
            sizeBytes: 1, capability: .ok)
        }
        let engine = SafetyEngine(
            safetyChecker: SafetyChecker(
                root: fixture.root,
                brimAppURL: fixture.folder.appendingPathComponent("Brim.app")
            ),
            vetoEngine: TierSVetoEngine(root: fixture.root)
        )
        let complete = await engine.evaluate(footprint: Footprint(identity: identity, items: items))
        #expect(complete.items.allSatisfy { $0.selection == .selected })
        let partial = await engine.evaluate(footprint: Footprint(identity: identity, items: items,
                                                                 completeness: ScanCompleteness(timedOut: [fixture
                                                                         .folder.path])))
        #expect(partial.items.allSatisfy { $0.selection == .unselected })
        let timing = FootprintItem(evidence: Evidence(url: items[0].evidence.url, tier: .C,
                                                      mechanism: "InstallRecordingSource",
                                                      humanSentence: "Timing only"),
                                   sizeBytes: 1, capability: .ok)
        let recorded = await engine.evaluate(footprint: Footprint(identity: identity, items: [timing]))
        #expect(recorded.items.first?.selection == .unselected)
    }

    @Test func anotherLiveInstallationKeepsTheCompanionsSharedDataAndPermissions() async throws {
        let fixture = try CompanionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let host = try fixture.bundle("Editor", identifier: "org.example.editor")
        let runtime = host.appendingPathComponent("Contents/MacOS/runtime")
        try FileManager.default.createDirectory(
            at: runtime.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: runtime)
        let wrapper = try fixture.wrapper("Link Launcher", target: runtime)
        _ = try fixture.bundle("Installed Launcher", identifier: "org.example.launcher")
        let cache = fixture.root.url(for: .userCaches).appendingPathComponent("org.example.launcher")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let identity = Identity(bundleID: "org.example.editor", name: "Editor", bundlePath: host.path)
        let footprint = try await FootprintProjector(engine: EvidenceEngine(sources: [
            AppBundleSource(), CompanionApplicationSource(), LocationInventorySource()
        ])).project(identity: identity, in: fixture.root)
        let evaluated = await SafetyEngine(
            safetyChecker: SafetyChecker(
                root: fixture.root,
                brimAppURL: fixture.folder.appendingPathComponent("Brim.app")
            ),
            vetoEngine: TierSVetoEngine(root: fixture.root)
        ).evaluate(footprint: footprint)
        let plan = Planner().createPlan(from: evaluated,
                                        intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
                                        engineVersion: "test")
        #expect(plan.steps.contains { $0.kind == .trashPath
                && URL(fileURLWithPath: $0.target).resolvingSymlinksInPath() == wrapper.resolvingSymlinksInPath()
        })
        #expect(!plan.steps.contains { $0.target == cache.path })
        #expect(plan.excludedItems.contains { $0.target == cache.path && $0.canBeTickedByHand == false })
        #expect(!plan.steps.contains { $0.kind == .resetPrivacyGrants && $0.target == "org.example.launcher" })
    }
}

private struct CompanionFixture {
    let folder: URL
    var root: FileSystemRoot {
        FileSystemRoot(rootURL: folder, userName: "tester")
    }

    init() throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func bundle(_ name: String, identifier: String, executable: String? = nil) throws -> URL {
        let app = root.url(for: .userApplications).appendingPathComponent(name + ".app")
        let metadata = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(
            at: metadata.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var info = ["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        info["CFBundleExecutable"] = executable
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: metadata)
        return app
    }

    func wrapper(_ name: String, target: URL) throws -> URL {
        let app = try bundle(name, identifier: "org.example.launcher", executable: "Editor")
        let executable = app.appendingPathComponent("Contents/MacOS/Editor")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: target)
        return app
    }
}
