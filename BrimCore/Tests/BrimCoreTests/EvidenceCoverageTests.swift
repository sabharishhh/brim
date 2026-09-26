import BrimCore
@testable import BrimScan
import XCTest

final class EvidenceCoverageTests: XCTestCase {
    private var root: FileSystemRoot!
    private let fileManager = FileManager.default
    private let identity = Identity(teamID: "EXAMPLETEAM", name: "Example")

    override func setUpWithError() throws {
        root = FileSystemRoot(rootURL: fileManager.temporaryDirectory
            .appendingPathComponent("coverage-\(UUID().uuidString)"), userName: "tester")
        try fileManager.createDirectory(at: root.rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try fileManager.removeItem(at: root.rootURL)
    }

    private func writeFile(_ url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
    }

    /// TeamIDSource used to turn every directory read failure into a clean,
    /// empty result. A file where a directory should be fails on any host.
    func testFailedGroupListingSurvivesAnEmptyResult() async throws {
        let directory = root.url(for: .userLibrary).appendingPathComponent("Group Containers")
        try writeFile(directory)
        let engine = EvidenceEngine(sources: [TeamIDSource()])
        let found = try await engine.discover(identity: identity, in: root)
        XCTAssertTrue(found.evidence.isEmpty)
        XCTAssertEqual(found.completeness.unreadable, [directory.path])
        XCTAssertFalse(found.completeness.isComplete)
    }

    func testAbsentAndEmptyGroupDirectoriesAreComplete() async throws {
        let engine = EvidenceEngine(sources: [TeamIDSource()])
        let absent = try await engine.discover(identity: identity, in: root)
        XCTAssertTrue(absent.completeness.isComplete)
        let directory = root.url(for: .userLibrary).appendingPathComponent("Group Containers")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let empty = try await engine.discover(identity: identity, in: root)
        XCTAssertTrue(empty.completeness.isComplete)
        XCTAssertTrue(empty.evidence.isEmpty)
    }

    func testFailedSiblingListingPreservesBothEvidenceAndGap() async throws {
        let container = root.url(for: .userLibrary)
            .appendingPathComponent("Group Containers/EXAMPLETEAM.shared")
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        let applications = root.url(for: .applications)
        try writeFile(applications)
        let found = try await EvidenceEngine(sources: [TeamIDSource()]).discover(identity: identity, in: root)
        XCTAssertEqual(found.evidence.map(\.url.path), [container.path])
        XCTAssertEqual(found.evidence.first?.tier, .C)
        XCTAssertEqual(found.completeness.unreadable, [applications.path])
    }

    func testLaunchdDirectoryFailureIsReported() async throws {
        let directory = root.url(for: .userLaunchAgents)
        try writeFile(directory)
        let app = Identity(bundleID: "org.example.app", name: "Example")
        let found = try await EvidenceEngine(sources: [LaunchdSource()]).discover(identity: app, in: root)
        XCTAssertEqual(found.completeness.unreadable, [directory.path])
    }

    /// This source is deliberately not LocationInventorySource. The former
    /// concrete-type check silently discarded every other source's gaps.
    private struct PartialSource: EvidenceSource {
        let items: [Evidence]
        let completeness: ScanCompleteness

        func evidence(for _: Identity, in _: FileSystemRoot) async throws -> [Evidence] {
            items
        }

        func scan(for _: Identity, in _: FileSystemRoot) async throws -> EvidenceFindings {
            EvidenceFindings(evidence: items, completeness: completeness)
        }
    }

    func testGapsReachTheApprovedPlanAndLeaveOnlyExplicitChoicesSelected() async throws {
        let item = root.url(for: .userApplicationSupport).appendingPathComponent("Example")
        let shared = root.url(for: .userApplicationSupport).appendingPathComponent("Shared")
        try writeFile(item)
        try writeFile(shared)
        let gaps = ScanCompleteness(unreadable: ["/unreadable"], timedOut: ["/slow"])
        let source = PartialSource(items: [
            Evidence(url: item, tier: .A, mechanism: "fixture", humanSentence: "Declared by the app."),
            Evidence(url: shared, tier: .S, mechanism: "fixture", humanSentence: "Shared with another app.")
        ], completeness: gaps)
        let engine = EvidenceEngine(sources: [source, source])
        let footprint = try await FootprintProjector(engine: engine).project(identity: identity, in: root)
        XCTAssertEqual(footprint.completeness, gaps, "Duplicate source gaps must be counted once.")
        XCTAssertEqual(footprint.items.count, 2)
        let safety = SafetyEngine(
            safetyChecker: SafetyChecker(root: root, brimAppURL: root.rootURL.appendingPathComponent("Brim.app")),
            vetoEngine: TierSVetoEngine(root: root)
        )
        let evaluated = await safety.evaluate(footprint: footprint)
        let planner = Planner()
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        let automatic = planner.createPlan(from: evaluated, intent: intent, engineVersion: EvidenceEngineRevision)
        XCTAssertTrue(automatic.steps.isEmpty)
        XCTAssertEqual(automatic.scanCompleteness, gaps)
        XCTAssertEqual(automatic.excludedItems.first { $0.target == item.path }?.canBeTickedByHand, true)

        let manual = planner.createPlan(
            from: evaluated, intent: intent.tickingByHand([item.path, shared.path]),
            engineVersion: EvidenceEngineRevision
        )
        XCTAssertEqual(manual.steps.map(\.target), [item.path])
        XCTAssertEqual(manual.scanCompleteness, gaps)
        let encoded = try JSONEncoder().encode(manual)
        XCTAssertEqual(try JSONDecoder().decode(Plan.self, from: encoded), manual)

        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        oldJSON.removeValue(forKey: "scanCompleteness")
        let oldPlan = try JSONDecoder().decode(Plan.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertNil(oldPlan.scanCompleteness)
        XCTAssertNotEqual(try oldPlan.contentHash(), try manual.contentHash(), "Approval includes the reported gaps.")
    }
}
