import XCTest
@testable import BrimScan
@testable import BrimCore
@testable import BrimFixtures

final class EvidenceSourceTests: XCTestCase {
    
    func testSourcesAgainstSandboxedManifest() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gen = FixtureTreeGenerator(rootURL: tempRoot)
        defer { gen.destroy() }
        try gen.generate()
        
        let root = FileSystemRoot(rootURL: tempRoot)
        let resolver = IdentityResolver(root: root)
        
        let bundleURL = tempRoot.appendingPathComponent("Applications/SandboxedApp.app")
        let resolved = await resolver.resolve(bundleURL: bundleURL)
        let identity = Identity(bundleID: resolved.bundleID, teamID: "SANDBOXID", name: resolved.name, version: resolved.version, isSandboxed: true, groupContainers: ["group.com.brim.sandboxed"], cdHash: resolved.cdHash)
        
        var evidence = [Evidence]()
        
        let sources: [EvidenceSource] = [
            
            AppBundleSource(),
            SandboxContainerSource(),
            BundleIdentifierComponentSource(),
            InstallerReceiptSource(),
            GroupContainerSource(),
            BundleIdentifierStateSource(),
            TeamIDSource(),
            LaunchServicesSource(),
            SMAppServiceSource()
        ]
        
        for source in sources {
            evidence.append(contentsOf: try await source.evidence(for: identity, in: root))
        }
        
        // Load expected manifest
        let manifestURL = Bundle.module.url(forResource: "sandboxed", withExtension: "json", subdirectory: "Manifests")!
        let manifest = try JSONDecoder().decode(ExpectedEvidenceManifest.self, from: Data(contentsOf: manifestURL))
        
        let uniqueEvidence = Array(Dictionary(grouping: evidence, by: { $0.url.path }).values.compactMap { $0.first })
        XCTAssertEqual(uniqueEvidence.count, manifest.expectedItems.count)
        
        for expected in manifest.expectedItems {
            let expectedURL = root.rootURL.appendingPathComponent(expected.relativePath)
            XCTAssertTrue(uniqueEvidence.contains { $0.url.standardizedFileURL == expectedURL.standardizedFileURL }, "Missing \(expected.relativePath)")
            if let matched = uniqueEvidence.first(where: { $0.url.standardizedFileURL == expectedURL.standardizedFileURL }) {
                XCTAssertEqual(matched.tier.rawValue, expected.tier)
                XCTAssertEqual(matched.humanSentence, expected.description)
            }
        }
    }
    
    func testSourcesAgainstClassicManifest() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gen = FixtureTreeGenerator(rootURL: tempRoot)
        defer { gen.destroy() }
        try gen.generate()
        
        let root = FileSystemRoot(rootURL: tempRoot)
        let resolver = IdentityResolver(root: root)
        
        let bundleURL = tempRoot.appendingPathComponent("Applications/ClassicApp.app")
        let resolved = await resolver.resolve(bundleURL: bundleURL)
        let identity = Identity(bundleID: resolved.bundleID, teamID: "TEAMID1234", name: resolved.name, version: resolved.version, isSandboxed: false, groupContainers: [], cdHash: resolved.cdHash)
        
        var evidence = [Evidence]()
        
        let sources: [EvidenceSource] = [
            
            AppBundleSource(),
            SandboxContainerSource(),
            BundleIdentifierComponentSource(),
            InstallerReceiptSource(),
            GroupContainerSource(),
            BundleIdentifierStateSource(),
            TeamIDSource(),
            LaunchServicesSource(),
            SMAppServiceSource()
        ]
        
        for source in sources {
            evidence.append(contentsOf: try await source.evidence(for: identity, in: root))
        }
        
        // Load expected manifest.
        //
        // `Application Support/ClassicApp.app` moved from Tier B to Tier C
        // here, and that was the point rather than a casualty. It is matched
        // on the application's name, and the inventory has always rated a
        // name match C: a golden file is only as good as the behaviour it
        // was copied from, and this one had copied down a source that called
        // a name match strong evidence and ticked the row for removal.
        let manifestURL = Bundle.module.url(forResource: "classic", withExtension: "json", subdirectory: "Manifests")!
        let manifest = try JSONDecoder().decode(ExpectedEvidenceManifest.self, from: Data(contentsOf: manifestURL))
        
        let uniqueEvidence = Array(Dictionary(grouping: evidence, by: { $0.url.path }).values.compactMap { $0.first })
        XCTAssertEqual(uniqueEvidence.count, manifest.expectedItems.count)
        
        for expected in manifest.expectedItems {
            let expectedURL = root.rootURL.appendingPathComponent(expected.relativePath)
            XCTAssertTrue(uniqueEvidence.contains { $0.url.standardizedFileURL == expectedURL.standardizedFileURL }, "Missing \(expected.relativePath)")
            if let matched = uniqueEvidence.first(where: { $0.url.standardizedFileURL == expectedURL.standardizedFileURL }) {
                XCTAssertEqual(matched.tier.rawValue, expected.tier)
                XCTAssertEqual(matched.humanSentence, expected.description)
            }
        }
    }
}
