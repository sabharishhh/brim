// swiftformat:disable wrapMultilineStatementBraces
import BrimCore
@testable import BrimScan
import XCTest

final class LeftoverDirectionAgreementTests: XCTestCase {
    func testInstalledNestedExtensionProtectsItsStateAndNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = FileSystemRoot(rootURL: directory, userName: "tester")
        let app = root.url(for: .applications).appendingPathComponent("Vendor/Editor.app")
        let helper = app.appendingPathComponent("Contents/PlugIns/Worker.appex")
        for (bundle, identifier, name) in [(app, "org.example.editor", "Editor"),
                                           (helper, "net.unrelated.worker", "WorkerData")] {
            let info = bundle.appendingPathComponent("Contents/Info.plist")
            try FileManager.default.createDirectory(at: info.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
                                                                  "CFBundleName": name],
                                               format: .xml, options: 0).write(to: info)
        }
        let paths = [root.url(for: .userCaches).appendingPathComponent("net.unrelated.worker"),
                     root.url(for: .userApplicationSupport).appendingPathComponent("workerdata")]
        for path in paths {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data([1]).write(to: path)
        }
        let leftovers = try await LeftoversScanner(root: root)
            .scanLeftovers(knownPastBundleIDs: ["net.unrelated.worker"])
        XCTAssertTrue(Set(paths.map(\.path)).isDisjoint(with: leftovers.map(\.url.path)))
    }

    func testUninstallEvidenceAndSweepAgreeForOneBundle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-direction-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = FileSystemRoot(rootURL: directory, userName: "testuser")
        let bundle = root.url(for: .applications).appendingPathComponent("Sample.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "org.example.sample", "CFBundleName": "Sample"],
            format: .xml, options: 0
        )
        try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        let locations: [(FileSystemRoot.Domain, String)] = [
            (.userApplicationSupport, "org.example.sample"),
            (.userPreferences, "org.example.sample.plist"),
            (.userCaches, "org.example.sample.ShipIt"),
            (.userRecentDocuments, "org.example.sample.sfl4"),
            (.userWebKit, "org.example.sample"),
            (.userGroupContainers, "group.org.example.sample")
        ]
        var expected = Set<String>()
        for (domain, name) in locations {
            let url = root.url(for: domain).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "data".write(to: url, atomically: true, encoding: .utf8)
            expected.insert(EvidenceEngine.identity(of: url))
        }
        let appleRecord = root.url(for: .userRecentDocuments)
            .appendingPathComponent("com.apple.Safari.sfl4")
        try "system record".write(to: appleRecord, atomically: true, encoding: .utf8)

        let identity = await IdentityResolver(root: root).resolve(bundleURL: bundle)
        let uninstallEvidence = try await EvidenceEngine.standard.discover(identity: identity, in: root)
        let auxiliary = uninstallEvidence.evidence.filter { $0.url.path != bundle.path }
        XCTAssertEqual(Set(auxiliary.map { EvidenceEngine.identity(of: $0.url) }), expected)

        let whileInstalled = try await LeftoversScanner(root: root).scanLeftovers()
        XCTAssertTrue(expected.isDisjoint(with: whileInstalled.map { EvidenceEngine.identity(of: $0.url) }))

        try FileManager.default.removeItem(at: bundle)
        let afterRemoval = try await LeftoversScanner(root: root)
            .scanLeftovers(knownPastBundleIDs: ["org.example.sample"])
        XCTAssertFalse(afterRemoval.contains { $0.url.lastPathComponent == appleRecord.lastPathComponent })
        let matching = afterRemoval.filter { expected.contains(EvidenceEngine.identity(of: $0.url)) }
        XCTAssertEqual(Set(matching.map { EvidenceEngine.identity(of: $0.url) }), expected)
        XCTAssertTrue(matching.allSatisfy { $0.category == .orphaned })
        XCTAssertTrue(matching.allSatisfy { $0.potentialOwner?.bundleID == "org.example.sample" })
    }
}
