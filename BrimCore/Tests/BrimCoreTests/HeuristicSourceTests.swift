import XCTest
@testable import BrimScan
@testable import BrimCore

final class HeuristicSourceTests: XCTestCase {
    func testHeuristicSourceFindsCorrelatedItems() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        let fm = FileManager.default
        
        let root = FileSystemRoot(rootURL: rootURL)
        let cachesURL = root.url(for: .userLibrary).appendingPathComponent("Caches")
        try fm.createDirectory(at: cachesURL, withIntermediateDirectories: true)
        
        // Exact match (should be skipped by heuristic, handled by Tier B source)
        try fm.createDirectory(at: cachesURL.appendingPathComponent("com.vendor.app"), withIntermediateDirectories: true)
        
        // Correlated by name
        let correlatedURL = cachesURL.appendingPathComponent("UniqueVendorAppCacheDir")
        try fm.createDirectory(at: correlatedURL, withIntermediateDirectories: true)
        
        // Unrelated
        try fm.createDirectory(at: cachesURL.appendingPathComponent("com.other.app"), withIntermediateDirectories: true)
        
        let identity = Identity(bundleID: "com.vendor.app", name: "UniqueVendorApp")
        
        let source = HeuristicSource()
        let evidence = try await source.evidence(for: identity, in: root)
        
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence[0].url.resolvingSymlinksInPath().path, correlatedURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(evidence[0].tier, .C)
    }
}
