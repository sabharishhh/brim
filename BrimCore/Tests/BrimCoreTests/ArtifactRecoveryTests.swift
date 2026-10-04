import BrimCore
@testable import BrimScan
import Darwin
import Foundation
import Testing

struct ArtifactRecoveryTests {
    @Test func hiddenContentIsMeasuredAndHardlinksAndOverlappingRootsCountOnce() throws {
        let fixture = try ArtifactFixture()
        let file = try fixture.put("project/node_modules/.pnpm/package/index.js", bytes: 8192)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.linkItem(at: file, to: folder.appendingPathComponent("linked.js"))
        let size = ArtifactSizer.measure(roots: [folder, file])
        #expect(size.state == .complete)
        #expect(size.logicalBytes == 8192)
        #expect(size.allocatedBytes == ArtifactSizer.measure(at: file).allocatedBytes)
        // The old Developer walker silently skipped the entire .pnpm store.
        #expect(DeveloperCacheScanner.size(of: fixture.root.appendingPathComponent("project/node_modules")) > 0)
    }

    @Test func rootSymlinkCountsOnlyTheLinkAndNeverItsTarget() throws {
        let fixture = try ArtifactFixture()
        let file = try fixture.put("outside/large", bytes: 100_000)
        let link = fixture.root.appendingPathComponent("linked-output")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file.deletingLastPathComponent())
        let measured = ArtifactSizer.measure(at: link)
        #expect(measured.logicalBytes < 100_000)
        #expect(measured.logicalBytes == Int64(file.deletingLastPathComponent().path.utf8.count))
        #expect(measured.state == .complete)
        let projected = FootprintProjector.measure(at: link, fm: .default)
        #expect(projected.bytes == measured.logicalBytes)
    }

    @Test func refusedReadIsAPartialEstimateAndAnExpiredBudgetIsUnknown() throws {
        let fixture = try ArtifactFixture()
        try fixture.put("output/visible", bytes: 4096)
        let inaccessible = try fixture.put("output/refused/hidden", bytes: 100_000).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: inaccessible.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inaccessible.path) }
        let size = ArtifactSizer.measure(at: fixture.root.appendingPathComponent("output"))
        #expect(size.state == .partial)
        #expect(size.logicalBytes == 4096)
        #expect(size.completeness.unreadable == [inaccessible.path])
        let stopped = ArtifactSizer.measure(at: fixture.root, budget: ScanBudget(total: 0))
        #expect(stopped.state == .unknown)
        #expect(!stopped.isEmpty)
        #expect(stopped.completeness.timedOut == [fixture.root.path])
        let row = DeveloperCache(
            name: "Output",
            tool: "Test",
            url: fixture.root,
            sizeBytes: 0,
            cost: .rebuilt,
            explanation: "Build output.",
            sizeMeasurement: .pending
        )
        #expect(row.sizeDescription == "Measuring")
        #expect(row.measured(using: stopped).sizeDescription == "Size unavailable")
    }

    @Test func dependencyRecoveryNeedsRecordsWhileCompiledOutputDoesNot() throws {
        let fixture = try ArtifactFixture()
        try fixture.put("Developer/flutter/pubspec.yaml")
        try fixture.put("Developer/flutter/.dart_tool/package_config.json")
        try fixture.put("Developer/flutter/build/output")
        try fixture.put("Developer/elixir/mix.exs")
        try fixture.put("Developer/elixir/deps/dependency/source.ex")
        try fixture.put("Developer/elixir/_build/output")
        let scanner = ProjectBuildScanner(search: { _, _ in nil })
        let before = scanner.scan(home: fixture.root)
        #expect(Set(before.map(\.url.lastPathComponent)) == ["build", "_build"])
        try fixture.put("Developer/flutter/pubspec.lock")
        try fixture.put("Developer/elixir/mix.lock")
        let restored = scanner.scan(home: fixture.root).filter { $0.cost == .restored }
        #expect(Set(restored.map(\.url.lastPathComponent)) == [".dart_tool", "deps"])
        #expect(restored.first { $0.url.lastPathComponent == "deps" }?.explanation
            .contains("mix deps.get, then mix compile") == true)
    }

    @Test func nodeLocksNameTheActualManagerAndFrameworkFoldersNeedDependencies() throws {
        let fixture = try ArtifactFixture()
        try fixture.put(
            "Developer/web/package.json",
            content: "{\"devDependencies\":{\"@sveltejs/kit\":\"2\",\"astro\":\"5\"}}"
        )
        try fixture.put("Developer/web/pnpm-lock.yaml")
        let dependencies = try fixture.put("Developer/web/node_modules/.pnpm/pkg/index.js").deletingLastPathComponent()
        try fixture.put("Developer/web/.next/output")
        try fixture.put("Developer/web/.svelte-kit/output")
        try fixture.put("Developer/web/node_modules/.astro/cache")
        try fixture.put("Developer/web/.astro/custom-data")
        let scanner = ProjectBuildScanner(search: { _, _ in nil })
        let rows = scanner.scan(home: fixture.root)
        #expect(!rows.contains { $0.url.lastPathComponent == ".next" })
        #expect(rows.contains { $0.url.lastPathComponent == ".svelte-kit" })
        #expect(!rows.contains { $0.url.path.hasSuffix("web/.astro") })
        let node = try #require(rows.first { $0.url.lastPathComponent == "node_modules" })
        #expect(node.cost == .restored)
        #expect(node.explanation.contains("pnpm install --frozen-lockfile"))
        #expect(node.sizeBytes > 0)
        #expect(DeveloperCache.estimatedTotal(of: rows.filter { $0.url.path.contains("node_modules") }) == node
            .sizeBytes)
        #expect(ProjectBuildScanner.classification(at: dependencies, home: fixture.root) == nil)
        try fixture.put("Developer/web/yarn.lock")
        #expect(!scanner.scan(home: fixture.root).contains { $0.url.lastPathComponent == "node_modules" })
        #expect(scanner.discover(home: fixture.root, excluding: [fixture.root.appendingPathComponent("Developer/web")])
            .isEmpty)
    }

    @Test func environmentsAreReportedAndProjectSymlinksCannotEscape() throws {
        let fixture = try ArtifactFixture()
        try fixture.put("Developer/python/requirements.txt")
        try fixture.put("Developer/python/.venv/local-package/custom.py")
        try fixture.put("outside/custom.py")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("Developer/python/.mypy_cache"),
            withDestinationURL: fixture.root.appendingPathComponent("outside")
        )
        let rows = ProjectBuildScanner(search: { _, _ in nil }).scan(home: fixture.root)
        #expect(rows.count == 1)
        #expect(rows[0].cost == .configured)
        #expect(rows[0].artifactClassification == .stateful)
    }

    @Test func cacheShapedSettingsGoToTrashAndStatefulArtifactsCannotBePromoted() async throws {
        let fixture = try ArtifactFixture()
        let url = try fixture.put("Library/Caches/settings/custom.plist").deletingLastPathComponent()
        let root = FileSystemRoot(rootURL: fixture.root)
        let engine = SafetyEngine(
            safetyChecker: SafetyChecker(root: root, brimAppURL: fixture.root.appendingPathComponent("Brim.app")),
            vetoEngine: TierSVetoEngine(root: root)
        )
        let evidence = Evidence(url: url, tier: .A, mechanism: "DirectTarget", humanSentence: "Chosen settings.")
        let ordinary = FootprintItem(evidence: evidence, sizeBytes: 1, capability: .ok)
        let evaluated = await engine.evaluate(footprint: Footprint(
            identity: Identity(name: "Settings"),
            items: [ordinary]
        ))
        #expect(evaluated.items[0].costOfError == .medium)
        let intent = PlanIntent(type: .uninstall, subjectIdentity: Identity(name: "Settings"), specificTarget: url)
        #expect(Planner().createPlan(from: evaluated, intent: intent, engineVersion: "test").steps[0]
            .effectiveDisposition == .trash)
        let stateful = FootprintItem(
            evidence: evidence,
            sizeBytes: 1,
            capability: .ok,
            artifactClassification: .stateful
        )
        let protected = await engine.evaluate(footprint: Footprint(
            identity: Identity(name: "Environment"),
            items: [stateful]
        ))
        let handTicked = intent.tickingByHand([url.path])
        #expect(Planner().createPlan(from: protected, intent: handTicked, engineVersion: "test").steps.isEmpty)
    }

    @Test func positiveCompiledClassificationDeletesOnceAndOverlappingPathsDoNotDuplicatePlans() async throws {
        let fixture = try ArtifactFixture()
        let file = try fixture.put("Developer/rust/target/debug/output")
        let target = file.deletingLastPathComponent().deletingLastPathComponent()
        let root = FileSystemRoot(rootURL: fixture.root)
        let engine = SafetyEngine(
            safetyChecker: SafetyChecker(root: root, brimAppURL: fixture.root.appendingPathComponent("Brim.app")),
            vetoEngine: TierSVetoEngine(root: root)
        )
        let items = [target, target, file].map { url in
            FootprintItem(
                evidence: Evidence(
                    url: url,
                    tier: .A,
                    mechanism: "ProjectBuildScanner",
                    humanSentence: "Compiled output."
                ),
                sizeBytes: 4096,
                capability: .ok,
                artifactClassification: .rebuildableOutput
            )
        }
        let evaluated = await engine.evaluate(footprint: Footprint(identity: Identity(name: "Rust"), items: items))
        let intent = PlanIntent(
            type: .uninstall,
            subjectIdentity: Identity(name: "Rust"),
            specificTargets: [target, target, file]
        )
        let plan = Planner().createPlan(from: evaluated, intent: intent, engineVersion: "test")
        #expect(plan.steps.count == 1)
        #expect(plan.expectedTotalBytes == 4096)
        #expect(plan.steps[0].effectiveDisposition == .delete)
    }

    @Test func snapshotRetentionAndRecoverableCapacityRemainUnknownAndOldPayloadsDecode() async throws {
        let fixture = try ArtifactFixture()
        let file = try fixture.put("output", bytes: 8192)
        let item = FootprintItem(
            evidence: Evidence(url: file, tier: .A, mechanism: "Test", humanSentence: "Measured file."),
            sizeBytes: 8192,
            capability: .ok
        )
        let account = await StorageAccountant().account(for: [item, item])
        #expect(account.logical == 8192)
        #expect(account.reclaimable == nil)
        #expect(account.pinned == nil)
        let old = Footprint(
            identity: Identity(name: "Test"),
            items: [item],
            reclaimableSizeBytes: 8192,
            snapshotPinnedBytes: 0
        )
        let decoded = try JSONDecoder().decode(Footprint.self, from: JSONEncoder().encode(old))
        #expect(decoded.reclaimableSizeBytes == 8192)
        #expect(decoded.items[0].sizeMeasurement == nil)
        #expect(decoded.items[0].artifactClassification == nil)
        let current = Footprint(identity: Identity(name: "Test"), items: [item])
        #expect(current.reclaimableSizeBytes == nil && current.snapshotPinnedBytes == nil)
    }
}

private final class ArtifactFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
    @discardableResult func put(_ relative: String, bytes: Int = 4096, content: String? = nil) throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (content.map { Data($0.utf8) } ?? Data(repeating: 1, count: bytes)).write(to: file)
        return file
    }
}
