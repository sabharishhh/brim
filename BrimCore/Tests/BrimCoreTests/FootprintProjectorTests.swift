@testable import BrimCore
@testable import BrimFixtures
@testable import BrimScan
import XCTest

final class FootprintProjectorTests: XCTestCase {
    func testProjectorCalculatesSizeAndFiltersDeletedItems() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gen = FixtureTreeGenerator(rootURL: tempRoot)
        defer { gen.destroy() }
        try gen.generate()

        let root = FileSystemRoot(rootURL: tempRoot)
        let resolver = IdentityResolver(root: root)

        let bundleURL = tempRoot.appendingPathComponent("Applications/SandboxedApp.app")
        let identity = await resolver.resolve(bundleURL: bundleURL)

        let engine = EvidenceEngine(sources: [
            AppBundleSource(),
            SandboxContainerSource(),
            BundleIdentifierComponentSource(),
            InstallerReceiptSource()
        ])

        let projector = FootprintProjector(engine: engine)
        let footprint = try await projector.project(identity: identity, in: root)

        XCTAssertEqual(footprint.identity.bundleID, "com.brim.sandboxed")

        // From sandboxed.json, we expect 3 items
        XCTAssertEqual(footprint.items.count, 3)

        // Every item should have a positive size since the fixture created some plist data or empty dirs
        for item in footprint.items {
            XCTAssertGreaterThanOrEqual(item.sizeBytes, 0)
        }

        // Now let's test the "query, never a stored object" invalidation invariant
        // Delete the group container
        let groupContainerURL = tempRoot.appendingPathComponent("Library/Group Containers/group.com.brim.sandboxed")
        try FileManager.default.removeItem(at: groupContainerURL)

        // Re-query immediately
        let updatedFootprint = try await projector.project(identity: identity, in: root)

        // Should instantly reflect the deletion
        XCTAssertEqual(updatedFootprint.items.count, 2)
        XCTAssertFalse(updatedFootprint.items.contains(where: { $0.evidence.url == groupContainerURL }))
    }

    func testParallelMeasurementsKeepEvidenceOrderAndBrokenLinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("data")
        let link = directory.appendingPathComponent("link")
        let missing = directory.appendingPathComponent("missing")
        try Data(repeating: 1, count: 200).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
        let evidence = [link, missing, file].map {
            Evidence(url: $0, tier: .A, mechanism: "test", humanSentence: "Explicit target")
        }
        let projector = FootprintProjector(engine: EvidenceEngine(sources: []))
        let footprint = try await projector.project(identity: Identity(name: "Fixture"),
                                                    in: FileSystemRoot(rootURL: directory), explicitEvidence: evidence)
        XCTAssertEqual(footprint.items.map(\.evidence.url), [link, file])
        XCTAssertEqual(footprint.items.last?.sizeBytes, 200)
        XCTAssertTrue(footprint.completeness.isComplete)
    }

    func testCapabilityPreChecks() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gen = FixtureTreeGenerator(rootURL: tempRoot)
        defer { gen.destroy() }
        try gen.generate()

        let root = FileSystemRoot(rootURL: tempRoot)
        let resolver = IdentityResolver(root: root)

        let bundleURL = tempRoot.appendingPathComponent("Applications/SandboxedApp.app")
        let identity = await resolver.resolve(bundleURL: bundleURL)

        let engine = EvidenceEngine(sources: [
            AppBundleSource(),
            SandboxContainerSource(),
            BundleIdentifierComponentSource()
        ])

        // Make the app bundle read-only to simulate EACCES
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: bundleURL.path)

        let projector = FootprintProjector(engine: engine)
        let footprint = try await projector.project(identity: identity, in: root)

        if let appItem = footprint.items.first(where: { $0.evidence.url == bundleURL }) {
            XCTAssertEqual(appItem.capability, Capability.needsHelper)
        } else {
            XCTFail("App bundle not found in footprint")
        }

        // Restore permissions for cleanup
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundleURL.path)
    }
}
