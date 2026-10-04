import BrimCore
import BrimScan
import Foundation
import Testing

struct HomebrewDownloadTests {
    @Test func completedLeafDownloadsAreTheOnlyTargetsAndLinksNeverContributeSize() throws {
        let fixture = try Fixture()
        let completed = try fixture.put(fixture.name("bottle.tar.gz"), bytes: 8192)
        let hidden = try fixture.put("unknown-data", bytes: 32000)
        try fixture.put(fixture.name("active.tar.gz") + ".incomplete")
        try FileManager.default.createSymbolicLink(
            at: fixture.downloads.appendingPathComponent(fixture.name("alias.tar.gz")),
            withDestinationURL: hidden
        )
        try FileManager.default.createDirectory(
            at: fixture.downloads.appendingPathComponent(fixture.name("custom-folder")),
            withIntermediateDirectories: true
        )
        let nested = fixture.downloads.appendingPathComponent(fixture.name("custom-folder") + "/source")
        try Data(repeating: 1, count: 100_000).write(to: nested)
        let result = HomebrewDownloadScanner.scan(home: fixture.home)
        #expect(result.completeness.isComplete)
        #expect(result.files == [completed])
        #expect(result.measurement.logicalBytes == 8192)
        #expect(HomebrewDownloadScanner.classification(at: completed, home: fixture.home) == .dependencyStore)
        #expect(HomebrewDownloadScanner.classification(at: hidden, home: fixture.home) == nil)
        #expect(HomebrewDownloadScanner.classification(at: fixture.downloads, home: fixture.home) == nil)
    }

    @Test(arguments: ["Library", "Caches", "Homebrew", "downloads"])
    func linkedRootComponentsRefuseTheWholeRead(component: String) throws {
        let fixture = try Fixture()
        let completed = try fixture.put(fixture.name("bottle.tar.gz"))
        let relative = switch component {
        case "Library": "Library"
        case "Caches": "Library/Caches"
        case "Homebrew": "Library/Caches/Homebrew"
        default: "Library/Caches/Homebrew/downloads"
        }
        let original = fixture.home.appendingPathComponent(relative)
        let moved = fixture.home.appendingPathComponent("redirected")
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
        let result = HomebrewDownloadScanner.scan(home: fixture.home)
        #expect(result.files.isEmpty)
        #expect(result.completeness.isComplete == false)
        #expect(HomebrewDownloadScanner.classification(at: completed, home: fixture.home) == nil)
    }

    @Test func entryLimitAndExpiredBudgetNeverSupplyPartialCleanupTargets() throws {
        let fixture = try Fixture()
        try fixture.put(fixture.name("one.tar.gz"))
        try fixture.put(fixture.name("two.tar.gz"))
        let limited = HomebrewDownloadScanner.scan(home: fixture.home, maximumEntries: 1)
        let expired = HomebrewDownloadScanner.scan(home: fixture.home, budget: ScanBudget(total: 0))
        for result in [limited, expired] {
            #expect(result.files.isEmpty)
            #expect(result.measurement.state == .unknown)
            #expect(result.completeness.isComplete == false)
        }
    }

    @Test func inProgressReplacementAndChangedLeafTypeInvalidateClassification() throws {
        let fixture = try Fixture()
        let completed = try fixture.put(fixture.name("bottle.tar.gz"))
        try fixture.put(completed.lastPathComponent + ".incomplete")
        #expect(HomebrewDownloadScanner.scan(home: fixture.home).files.isEmpty)
        #expect(HomebrewDownloadScanner.classification(at: completed, home: fixture.home) == nil)
        try FileManager.default
            .removeItem(at: fixture.downloads.appendingPathComponent(completed.lastPathComponent + ".incomplete"))
        try FileManager.default.removeItem(at: completed)
        try FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)
        #expect(HomebrewDownloadScanner.classification(at: completed, home: fixture.home) == nil)
    }

    @Test func unknownNamesAndCustomCacheLocationsCannotBeClassified() throws {
        let fixture = try Fixture()
        for name in [
            "source.tar.gz",
            String(repeating: "a", count: 63) + "--bottle.tar.gz",
            String(repeating: "g", count: 64) + "--bottle.tar.gz",
            fixture.name("")
        ] {
            let url = try fixture.put(name)
            #expect(HomebrewDownloadScanner.classification(at: url, home: fixture.home) == nil)
        }
        let outside = fixture.home.appendingPathComponent(fixture.name("outside.tar.gz"))
        try Data([1]).write(to: outside)
        #expect(HomebrewDownloadScanner.classification(at: outside, home: fixture.home) == nil)
        #expect(HomebrewDownloadScanner.scan(home: fixture.home).files.isEmpty)
    }

    private final class Fixture {
        let home: URL
        let downloads: URL
        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("brim-homebrew-" + UUID().uuidString)
            downloads = HomebrewDownloadScanner.root(home: home)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: home) }
        func name(_ basename: String) -> String {
            String(repeating: "a", count: 64) + "--" + basename
        }

        @discardableResult func put(_ name: String, bytes: Int = 4096) throws -> URL {
            let url = downloads.appendingPathComponent(name)
            try Data(repeating: 1, count: bytes).write(to: url)
            return url
        }
    }
}
