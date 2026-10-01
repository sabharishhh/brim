import BrimCore
@testable import BrimOps
import Foundation
import Testing

struct SwiftPackageCacheValidationTests {
    private let stopped = ToolCleanup.CleanupError.configurationUnavailable(
        "The package cache check did not finish. Nothing was cleaned."
    )

    @Test func aSmallEntryBudgetRefusesTheCacheInsteadOfReturningAPartialApproval() throws {
        let fixture = try CacheValidationFixture()
        for name in ["first", "second", "third"] {
            try fixture.put(name)
        }
        #expect(throws: stopped) {
            try ToolCleanup.Client.checkSwiftPMPaths(fixture.cache, maximumEntries: 2)
        }
        try ToolCleanup.Client.checkSwiftPMPaths(fixture.cache, maximumEntries: 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).count == 3)
    }

    @Test func theEntryBudgetIsSharedByAllFourSupportedFolders() throws {
        let fixture = try CacheValidationFixture()
        try fixture.put("manifests/cached")
        try fixture.put("registry/downloads/cached")
        // Two roots, one manifest, the downloads folder and its one file.
        #expect(throws: stopped) {
            try ToolCleanup.Client.checkSwiftPMPaths(fixture.cache, maximumEntries: 4)
        }
        try ToolCleanup.Client.checkSwiftPMPaths(fixture.cache, maximumEntries: 5)
    }

    @Test func anExpiredCheckRefusesEvenAnEmptyCache() throws {
        let fixture = try CacheValidationFixture()
        #expect(throws: stopped) {
            try ToolCleanup.Client.checkSwiftPMPaths(fixture.cache, budget: ScanBudget(total: 0))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.cache.path))
    }

    @Test(arguments: ["manifests", "registry/downloads", "CACHEDIR.TAG"])
    func shallowLinksAreRefusedWithoutInspectingTheirTarget(relative: String) throws {
        let fixture = try CacheValidationFixture()
        let target = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = fixture.cache.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: ToolCleanup.CleanupError.configurationUnavailable(
            "The package cache contains a link. Manage this cache in Xcode so its scope can be reviewed."
        )) {
            try ToolCleanup.Client.checkSwiftPMPaths(fixture.cache)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func theValidatorKeepsItsShallowScopeInsteadOfRecursingIntoRepositories() throws {
        let fixture = try CacheValidationFixture()
        let target = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = fixture.cache.appendingPathComponent("repositories/package/local-link")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try ToolCleanup.Client.checkSwiftPMPaths(fixture.cache, maximumEntries: 1)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }
}

private final class CacheValidationFixture {
    let root: URL
    let cache: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpm-check-\(UUID().uuidString)")
        cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult func put(_ path: String) throws -> URL {
        let file = cache.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: file)
        return file
    }
}
