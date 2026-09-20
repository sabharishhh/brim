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
        let identity = await resolver.resolve(bundleURL: bundleURL)
        
        var evidence = [Evidence]()
        
        let sources: [EvidenceSource] = [
            AppBundleSource(bundleURL: bundleURL),
            SandboxContainerSource(),
            BundleIdentifierComponentSource(),
            InstallerReceiptSource()
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
            XCTAssertTrue(uniqueEvidence.contains { $0.url == expectedURL }, "Missing \(expected.relativePath)")
            if let matched = uniqueEvidence.first(where: { $0.url == expectedURL }) {
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
        let identity = await resolver.resolve(bundleURL: bundleURL)
        
        var evidence = [Evidence]()
        
        let sources: [EvidenceSource] = [
            AppBundleSource(bundleURL: bundleURL),
            SandboxContainerSource(),
            BundleIdentifierComponentSource(),
            InstallerReceiptSource()
        ]
        
        for source in sources {
            evidence.append(contentsOf: try await source.evidence(for: identity, in: root))
        }
        
        // Load expected manifest
        let manifestURL = Bundle.module.url(forResource: "classic", withExtension: "json", subdirectory: "Manifests")!
        let manifest = try JSONDecoder().decode(ExpectedEvidenceManifest.self, from: Data(contentsOf: manifestURL))
        
        let uniqueEvidence = Array(Dictionary(grouping: evidence, by: { $0.url.path }).values.compactMap { $0.first })
        XCTAssertEqual(uniqueEvidence.count, manifest.expectedItems.count)
        
        for expected in manifest.expectedItems {
            let expectedURL = root.rootURL.appendingPathComponent(expected.relativePath)
            XCTAssertTrue(uniqueEvidence.contains { $0.url == expectedURL }, "Missing \(expected.relativePath)")
            if let matched = uniqueEvidence.first(where: { $0.url == expectedURL }) {
                XCTAssertEqual(matched.tier.rawValue, expected.tier)
                XCTAssertEqual(matched.humanSentence, expected.description)
            }
        }
    }
}
