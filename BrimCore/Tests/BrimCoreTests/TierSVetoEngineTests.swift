import XCTest
@testable import BrimCore

final class TierSVetoEngineTests: XCTestCase {
    func testVetoEngineExcludesSharedFiles() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let root = FileSystemRoot(rootURL: tempRoot)
        let vetoEngine = TierSVetoEngine(root: root)

        let identity = Identity(bundleID: "com.test.app", name: "TestApp")

        let safeURL = tempRoot.appendingPathComponent("SafeFile")
        let sharedURL = tempRoot.appendingPathComponent("OtherApp.app")
        try FileManager.default.createDirectory(at: sharedURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "com.other.app"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: sharedURL.appendingPathComponent("Contents/Info.plist"))

        let items = [
            EvaluatedItem(footprintItem: FootprintItem(evidence: Evidence(url: safeURL, tier: .A, mechanism: "Test", humanSentence: "Safe"), sizeBytes: 100, capability: .ok), selection: .selected, costOfError: .low),
            EvaluatedItem(footprintItem: FootprintItem(evidence: Evidence(url: sharedURL, tier: .A, mechanism: "Test", humanSentence: "Shared"), sizeBytes: 100, capability: .ok), selection: .selected, costOfError: .low)
        ]

        let footprint = EvaluatedFootprint(identity: identity, items: items)
        let vetted = await vetoEngine.applyVeto(to: footprint)

        XCTAssertEqual(vetted.items.count, 2)
        XCTAssertEqual(vetted.items[0].selection, .selected)

        if case let .excluded(reason) = vetted.items[1].selection {
            XCTAssertTrue(reason.contains("claimed by OtherApp"), "Expected exclusion reason to contain claimant name")
        } else {
            XCTFail("Expected shared file to be excluded")
        }
    }

    func testUntickedForeignBundleCannotBePromotedByUninstall() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileSystemRoot(rootURL: folder)
        let target = folder.appendingPathComponent("Other.app")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.other.app"],
                                           format: .xml, options: 0)
            .write(to: target.appendingPathComponent("Contents/Info.plist"))
        let identity = Identity(bundleID: "org.example.app", name: "Example")
        let item = EvaluatedItem(footprintItem: FootprintItem(
            evidence: Evidence(url: target, tier: .C, mechanism: "test", humanSentence: "Name match"),
            sizeBytes: 1, capability: .ok
        ), selection: .unselected, costOfError: .medium)
        let vetted = await TierSVetoEngine(root: root).applyVeto(
            to: EvaluatedFootprint(identity: identity, items: [item])
        )
        guard case .excluded = vetted.items[0].selection else { return XCTFail("Shared row remained tickable") }
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity).tickingByHand([target.path])
        let plan = Planner().createPlan(from: vetted, intent: intent, engineVersion: "test")
        XCTAssertFalse(plan.steps.contains { $0.target == target.path })
        XCTAssertEqual(plan.excludedItems.first?.canBeTickedByHand, false)
    }

    func testNestedAppClaimAndIncompleteOwnershipVetoUntickedGroups() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = FileSystemRoot(rootURL: folder, userName: "tester")
        let other = root.url(for: .applications).appendingPathComponent("Vendor/Other.app")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let target = root.url(for: .userGroupContainers).appendingPathComponent("group.org.example.shared")
        let item = EvaluatedItem(footprintItem: FootprintItem(
            evidence: Evidence(url: target, tier: .A, mechanism: "test", humanSentence: "Declared group"),
            sizeBytes: 1, capability: .ok
        ), selection: .unselected, costOfError: .medium)
        let footprint = EvaluatedFootprint(identity: Identity(name: "Example"), items: [item])
        let claimed = TierSVetoEngine(root: root) { bundle, _ in
            (bundle.lastPathComponent == "Other.app" ? ["group.org.example.shared"] : [], true)
        }
        let result = await claimed.applyVeto(to: footprint)
        XCTAssertEqual(result.items[0].selection, .excluded(reason: "Shared with Other."))

        let incomplete = TierSVetoEngine(root: root) { _, _ in ([], false) }
        let unavailable = await incomplete.applyVeto(to: footprint)
        XCTAssertEqual(unavailable.items[0].selection,
                       .excluded(reason: "Shared ownership could not be checked."))
    }
}
