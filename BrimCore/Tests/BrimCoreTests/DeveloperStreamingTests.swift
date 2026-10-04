import BrimCore
@testable import BrimScan
import Foundation
import Testing

struct DeveloperStreamingTests {
    @Test func discoveryArrivesBeforeSizingAndWorkersStayBounded() async throws {
        let fixture = try DeveloperScanFixture()
        defer { fixture.remove() }
        try fixture.makeKnownFolders()
        let meter = MeasurementMeter()
        let scanner = DeveloperCacheScanner(
            home: fixture.home,
            darwinCache: fixture.darwinCache
        ) { _, _ in
            await meter.started()
            try? await Task.sleep(for: .milliseconds(100))
            await meter.finished()
            return ArtifactSize(logicalBytes: 4096, allocatedBytes: 4096, state: .complete)
        }
        let clock = ContinuousClock()
        let began = clock.now
        var firstLatency: Duration?
        var final: [DeveloperCache] = []
        for await snapshot in await scanner.updates() {
            if firstLatency == nil {
                firstLatency = began.duration(to: clock.now)
                #expect(snapshot.count == 6)
                #expect(snapshot.allSatisfy { $0.sizeMeasurement?.state == .pending })
            }
            final = snapshot
        }
        #expect(final.allSatisfy { $0.sizeMeasurement?.state == .complete })
        #expect(await meter.maximum == 4)
        #expect(await meter.totalStarted == 6)
        // A fixed six-row sizing fixture establishes latency without asserting
        // scheduler-sensitive timings. The old list arrived after all sizes.
        let firstSnapshot = String(describing: firstLatency)
        let allSizes = began.duration(to: clock.now)
        print("Developer fixture first snapshot: \(firstSnapshot); all sizes: \(allSizes)")
    }

    @Test func cancellingTheConsumerSettlesOnlyItsSizingWork() async throws {
        let fixture = try DeveloperScanFixture()
        defer { fixture.remove() }
        try fixture.makeKnownFolders()
        let meter = MeasurementMeter()
        let scanner = DeveloperCacheScanner(
            home: fixture.home,
            darwinCache: fixture.darwinCache
        ) { _, _ in
            await meter.started()
            try? await Task.sleep(for: .seconds(30))
            await meter.finished()
            return ArtifactSize(state: .unknown)
        }
        let consumer = Task {
            for await _ in await scanner.updates() {}
        }
        try await waitUntil { await meter.totalStarted == 4 }
        consumer.cancel()
        await consumer.value
        try await waitUntil { await meter.active == 0 }
        #expect(await meter.totalStarted == 4)
    }

    @Test func newSharedStoresUseDocumentedLocationsAndStayWithTheirTools() async throws {
        let fixture = try DeveloperScanFixture()
        defer { fixture.remove() }
        let defaults = [".bun/install/cache", "Library/Caches/deno", ".nuget/packages",
                        "Library/Caches/Yarn", ".yarn/berry/cache"]
        for path in defaults {
            try fixture.put(path + "/data")
        }
        let custom = ["BUN_INSTALL_CACHE_DIR": fixture.home.appendingPathComponent("tool-stores/bun").path,
                      "DENO_DIR": fixture.home.appendingPathComponent("tool-stores/deno").path,
                      "NUGET_PACKAGES": fixture.home.appendingPathComponent("tool-stores/nuget").path,
                      "YARN_CACHE_FOLDER": fixture.home.appendingPathComponent("tool-stores/yarn1").path,
                      "YARN_GLOBAL_FOLDER": fixture.home.appendingPathComponent("tool-stores/yarn2").path]
        for (key, path) in custom {
            try fixture.put(String(path.dropFirst(fixture.home.path.count + 1))
                + (key == "YARN_GLOBAL_FOLDER" ? "/cache" : "") + "/data")
        }
        // A sibling holding credentials and setup is not a package cache.
        try fixture.put(".bun/bin/bun")
        try fixture.put(".nuget/NuGet/NuGet.Config")
        let scanner = DeveloperCacheScanner(
            home: fixture.home,
            darwinCache: fixture.darwinCache,
            projects: nil,
            updates: nil,
            oldVersions: nil,
            environment: custom
        )
        let rows = await scanner.scan()
        #expect(rows.count == 10)
        #expect(rows.allSatisfy { $0.cost == .refetched && $0.cleanupID == nil })
        #expect(rows.allSatisfy { $0.manualCleanupReason != nil })
        let claimed = DeveloperCacheScanner.claimedPaths(home: fixture.home,
                                                         darwinCache: fixture.darwinCache,
                                                         environment: custom)
        #expect(rows.allSatisfy { claimed.contains($0.url.path) })
        #expect(!claimed.contains(fixture.home.appendingPathComponent(".bun/bin").path))
        #expect(!claimed.contains(fixture.home.appendingPathComponent(".nuget/NuGet").path))
        for row in rows {
            #expect(DeveloperCacheScanner.classification(at: row.url, home: fixture.home,
                                                         darwinCache: fixture.darwinCache,
                                                         environment: custom) == .toolManaged)
        }
    }

    @Test func exclusionsAndUnsafeConfiguredRootsDoNotBecomeCacheRows() async throws {
        let fixture = try DeveloperScanFixture()
        defer { fixture.remove() }
        try fixture.put(".bun/install/cache/data")
        try fixture.put("Library/Caches/deno/data")
        let darwin = fixture.darwinCache
        let scanner = DeveloperCacheScanner(home: fixture.home, darwinCache: darwin, projects: nil,
                                            updates: nil, oldVersions: nil,
                                            environment: ["BUN_INSTALL_CACHE_DIR": fixture.home.path,
                                                          "DENO_DIR": "/"],
                                            excludedFolders: [fixture.home
                                                .appendingPathComponent(".bun/install/cache/data")])
        let rows = await scanner.scan()
        #expect(rows.map(\.tool) == ["Deno"])
        let claimed = DeveloperCacheScanner.claimedPaths(home: fixture.home, darwinCache: darwin,
                                                         environment: ["BUN_INSTALL_CACHE_DIR": fixture.home.path,
                                                                       "DENO_DIR": "/"])
        #expect(!claimed.contains(fixture.home.path))
        #expect(!claimed.contains("/"))
        try FileManager.default.createDirectory(at: fixture.home.appendingPathComponent(".nuget"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.home.appendingPathComponent(".nuget/packages"),
                                                   withDestinationURL: fixture.home)
        #expect(DeveloperCacheScanner.classification(at: fixture.home.appendingPathComponent(".nuget/packages"),
                                                     home: fixture.home, darwinCache: darwin) == .toolManaged)
    }

    private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while await !predicate(), ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await predicate())
    }
}

struct DeveloperStorePolicyTests {
    @Test func explicitStoreChildrenAndParentsCannotBypassTheirDisposalPolicy() async throws {
        let fixture = try DeveloperScanFixture()
        defer { fixture.remove() }
        try fixture.put(".npm/_cacache/index/entry")
        try fixture.put("Library/Caches/org.swift.swiftpm/repositories/package/source.swift")
        try fixture.put("Library/Developer/Xcode/Archives/release/App.xcarchive/data")
        let root = FileSystemRoot(rootURL: fixture.home)
        let engine = SafetyEngine(
            safetyChecker: SafetyChecker(root: root, brimAppURL: fixture.home.appendingPathComponent("Brim.app")),
            vetoEngine: TierSVetoEngine(root: root)
        )
        let paths = [".npm/_cacache", ".npm/_cacache/index/entry", ".npm", "Library/Caches",
                     "Library/Developer/Xcode/Archives/release/App.xcarchive/data", "Library/Developer/Xcode"]
        for path in paths {
            let url = fixture.home.appendingPathComponent(path)
            let classification = try #require(DeveloperCacheScanner.classification(
                at: url, home: fixture.home, darwinCache: fixture.darwinCache,
                environment: [:]
            ))
            #expect(classification == (path.contains("Xcode") ? .stateful : .toolManaged))
            let item = FootprintItem(
                evidence: Evidence(url: url, tier: .A, mechanism: "DirectTarget", humanSentence: "Chosen path."),
                sizeBytes: 4096,
                capability: .ok,
                artifactClassification: classification
            )
            let evaluated = await engine.evaluate(footprint: Footprint(
                identity: Identity(name: "Store"),
                items: [item]
            ))
            let intent = PlanIntent(type: .uninstall, subjectIdentity: Identity(name: "Store"), specificTarget: url)
                .tickingByHand([url.path])
            let plan = Planner().createPlan(from: evaluated, intent: intent, engineVersion: "test")
            #expect(plan.steps.isEmpty)
            #expect(plan.excludedItems.count == 1)
            #expect(plan.excludedItems.first?.canBeTickedByHand == false)
            if classification == .toolManaged {
                #expect(evaluated.items[0].costOfError == .medium)
                #expect(plan.excludedItems.first?.reason == "Managed by its tool. Use its cleanup action.")
            }
        }
    }

    @Test func anExcludedProjectChildAlsoProtectsTheDependencyParentAndAliases() throws {
        let fixture = try DeveloperScanFixture()
        defer { fixture.remove() }
        let marker = fixture.home.appendingPathComponent("Developer/web/package.json")
        try fixture.put("Developer/web/package.json")
        try Data("{\"devDependencies\":{\"astro\":\"5\"}}".utf8).write(to: marker)
        try fixture.put("Developer/web/package-lock.json")
        try fixture.put("Developer/web/node_modules/.astro/cache")
        let dependencies = fixture.home.appendingPathComponent("Developer/web/node_modules")
        let alias = fixture.home.appendingPathComponent("dependency-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dependencies)
        let scanner = ProjectBuildScanner(search: { _, _ in [marker] })
        #expect(scanner.discover(home: fixture.home).count == 2)
        #expect(scanner.discover(home: fixture.home, excluding: [dependencies.appendingPathComponent(".astro")])
            .isEmpty)
        #expect(scanner.discover(home: fixture.home, excluding: [alias.appendingPathComponent(".astro")]).isEmpty)
    }

    @Test func provenProjectEnvironmentsProtectDeepChildrenAndParentsOnlyWithProjectEvidence() throws {
        let fixture = try DeveloperScanFixture()
        defer { fixture.remove() }
        try fixture.put("Developer/python/pyproject.toml")
        try fixture.put("Developer/python/.venv/lib/python/site-packages/local/package.py")
        try fixture.put("Developer/python/.mypy_cache/output")
        try fixture.put("Developer/unrelated/venv/local-file")
        let environment = fixture.home.appendingPathComponent("Developer/python/.venv")
        let alias = fixture.home.appendingPathComponent("environment-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: environment)
        let protectedURLs = [
            environment,
            environment.appendingPathComponent("lib/python/site-packages/local/package.py"),
            environment.deletingLastPathComponent(),
            alias.appendingPathComponent("lib/python/site-packages/local/package.py")
        ]
        for url in protectedURLs {
            #expect(ProjectBuildScanner.classification(at: url, home: fixture.home) == .stateful)
        }
        #expect(ProjectBuildScanner.classification(
            at: fixture.home.appendingPathComponent("Developer/unrelated/venv/local-file"),
            home: fixture.home
        ) == nil)
        #expect(ProjectBuildScanner.classification(
            at: fixture.home.appendingPathComponent("Developer/python/.mypy_cache"),
            home: fixture.home
        ) == .rebuildableCache)
        #expect(ProjectBuildScanner.classification(
            at: fixture.home.appendingPathComponent("Developer/python/.mypy_cache/output"),
            home: fixture.home
        ) == nil)
    }

    @Test func replacedProtectedRootsStillProtectDirectChildren() throws {
        let fixture = try DeveloperScanFixture()
        defer { fixture.remove() }
        try fixture.put("alternate-cache/package/source.js")
        try fixture.put("alternate-archives/release/data")
        try fixture.put("ordinary-output/data")
        let links = [(".npm/_cacache", "alternate-cache"),
                     ("Library/Developer/Xcode/Archives", "alternate-archives"),
                     (".nuget/packages", "missing-packages"),
                     ("Library/Developer/Xcode/DerivedData", "ordinary-output")]
        for (path, destination) in links {
            let link = fixture.home.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: fixture.home.appendingPathComponent(destination)
            )
        }
        try fixture.put("Library/Caches/org.swift.swiftpm")
        let darwin = fixture.darwinCache
        let protectedPaths = [".npm/_cacache/package/source.js", ".nuget/packages/missing-child",
                              "Library/Caches/org.swift.swiftpm"]
        for path in protectedPaths {
            #expect(DeveloperCacheScanner.classification(at: fixture.home.appendingPathComponent(path),
                                                         home: fixture.home, darwinCache: darwin, environment: [:]) ==
                    .toolManaged)
        }
        #expect(DeveloperCacheScanner
            .classification(at: fixture.home.appendingPathComponent("Library/Developer/Xcode/Archives/release/data"),
                            home: fixture.home, darwinCache: darwin, environment: [:]) ==
            .stateful)
        #expect(DeveloperCacheScanner.classification(
            at: fixture.home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
            home: fixture.home,
            darwinCache: darwin,
            environment: [:]
        ) == nil)
    }
}

private actor MeasurementMeter {
    private(set) var active = 0
    private(set) var maximum = 0
    private(set) var totalStarted = 0
    func started() {
        active += 1; totalStarted += 1; maximum = max(maximum, active)
    }

    func finished() {
        active -= 1
    }
}

private struct DeveloperScanFixture {
    let home: URL
    var darwinCache: URL {
        home.appendingPathComponent("darwin")
    }

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("developer-stream-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func put(_ relative: String) throws {
        let file = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: 4096).write(to: file)
    }

    func makeKnownFolders() throws {
        let knownPaths = ["Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives",
                          "Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/CoreSimulator/Devices",
                          "Library/Developer/CoreSimulator/Caches", "Library/Caches/org.swift.swiftpm"]
        for path in knownPaths {
            try put(path + "/data")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}
