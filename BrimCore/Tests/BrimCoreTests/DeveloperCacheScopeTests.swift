import BrimCore
@testable import BrimScan
import Foundation
import Testing

struct DeveloperCacheScopeTests {
    @Test(arguments: ["Library", "Library/Developer", "Library/Developer/Xcode"], [true, false])
    func linkedAncestryCannotBecomePositiveCacheEvidence(_ relative: String, insideHome: Bool) async throws {
        let fixture = try CacheScopeFixture()
        defer { fixture.remove() }
        let target = try fixture.put("home/Library/Developer/Xcode/DerivedData/output")
            .deletingLastPathComponent()
        let original = fixture.home.appendingPathComponent(relative)
        let moved = (insideHome ? fixture.home : fixture.base).appendingPathComponent("redirected")
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
        #expect(ProjectBuildScanner.isRealFolder(target))
        #expect(fixture.classification(target) == nil)
        #expect(await fixture.scanner().scan().isEmpty)
    }

    @Test func userAndDarwinCachesRequireTheirOwnUnlinkedRoots() async throws {
        let fixture = try CacheScopeFixture()
        defer { fixture.remove() }
        let user = try fixture.put("home/Library/Developer/Xcode/DerivedData/output").deletingLastPathComponent()
        let clang = try fixture.put("darwin-cache/clang/module.pcm").deletingLastPathComponent()
        #expect(!clang.path.hasPrefix(fixture.home.path + "/"))
        #expect(fixture.classification(user) == .rebuildableCache)
        #expect(fixture.classification(clang) == .rebuildableCache)
        #expect(await Set(fixture.scanner().scan().map(\.tool)) == ["Xcode", "Clang"])
        // A system alias above the supplied Darwin root is not part of the
        // relative cache path. The root itself and every child must be real.
        let alias = fixture.base.appendingPathComponent("cache-prefix-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.base)
        let darwin = alias.appendingPathComponent("darwin-cache")
        let aliasedClang = darwin.appendingPathComponent("clang")
        #expect(DeveloperCacheScanner.classification(
            at: aliasedClang, home: fixture.home, darwinCache: darwin, environment: [:]
        ) == .rebuildableCache)
    }

    @Test(arguments: ["home", "darwin-cache"])
    func linkedSuppliedRootsCannotPromoteCacheContents(_ rootName: String) async throws {
        let fixture = try CacheScopeFixture()
        defer { fixture.remove() }
        let relative = rootName == "home" ? "home/Library/Developer/Xcode/DerivedData" : "darwin-cache/clang"
        let target = try fixture.put(relative + "/output").deletingLastPathComponent()
        let supplied = fixture.base.appendingPathComponent(rootName)
        let moved = fixture.base.appendingPathComponent("actual-root")
        try FileManager.default.moveItem(at: supplied, to: moved)
        try FileManager.default.createSymbolicLink(at: supplied, withDestinationURL: moved)
        #expect(fixture.classification(target) == nil)
        #expect(await fixture.scanner().scan().isEmpty)
    }

    @Test func configuredLinkedStoresRemainReportOnlyAndUvDoesNotPromiseRestoration() async throws {
        let fixture = try CacheScopeFixture()
        defer { fixture.remove() }
        let data = try fixture.put("shared/bun/data")
        let alias = fixture.home.appendingPathComponent("tool-stores")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: fixture.base.appendingPathComponent("shared")
        )
        let configured = alias.appendingPathComponent("bun")
        let environment = ["BUN_INSTALL_CACHE_DIR": configured.path]
        try fixture.put("home/.cache/uv/archive/data")
        let rows = await fixture.scanner(environment: environment).scan()
        let bun = try #require(rows.first { $0.tool == "Bun" })
        #expect(bun.cost == .refetched && bun.cleanupID == nil && bun.manualCleanupReason != nil)
        #expect(DeveloperCacheScanner.classification(
            at: data, home: fixture.home, darwinCache: fixture.darwin, environment: environment
        ) == .toolManaged)
        let uvCache = try #require(rows.first { $0.tool == "uv" })
        #expect(uvCache.explanation.contains("break those environments"))
        #expect(!uvCache.explanation.contains("Fetched again"))
    }
}

private struct CacheScopeFixture {
    let base: URL
    var home: URL {
        base.appendingPathComponent("home")
    }

    var darwin: URL {
        base.appendingPathComponent("darwin-cache")
    }

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("CacheScope-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    @discardableResult func put(_ relative: String) throws -> URL {
        let file = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: file)
        return file
    }

    func scanner(environment: [String: String] = [:]) -> DeveloperCacheScanner {
        DeveloperCacheScanner(home: home, darwinCache: darwin, projects: nil, updates: nil,
                              oldVersions: nil, environment: environment)
    }

    func classification(_ target: URL) -> ArtifactClassification? {
        DeveloperCacheScanner.classification(at: target, home: home, darwinCache: darwin, environment: [:])
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
