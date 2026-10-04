import BrimCore
@testable import BrimScan
import Foundation
import Testing

/// The nested search used to skip refused reads and every child after 500,
/// then report a complete footprint. These fixtures stay in a temporary tree.
struct NestedSearchCompletenessTests {
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let identity = Identity(bundleID: "zz.example.editor", name: "Editor")
        var locked: [URL] = []
        var root: FileSystemRoot {
            FileSystemRoot(rootURL: directory, userName: "tester")
        }

        deinit {
            for url in locked {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: url.path
                )
            }
            try? FileManager.default.removeItem(at: directory)
        }

        func folder(_ url: URL) throws -> URL {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func file(_ url: URL) throws -> URL {
            _ = try folder(url.deletingLastPathComponent())
            try Data([1]).write(to: url)
            return url
        }

        func refuse(_ url: URL) throws {
            locked.append(url)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            #expect(DirectoryEntries.read(url).isRefused, "The fixture must actually refuse enumeration.")
        }
    }

    @Test func anOwnedChildAfterFiveHundredEntriesIsNotSilentlyLost() async throws {
        let fixture = Fixture()
        let parent = try fixture.folder(fixture.root.url(for: .userApplicationSupport).appendingPathComponent("SDK"))
        for index in 0 ..< 501 {
            _ = try fixture.file(parent.appendingPathComponent(String(format: "a%04d", index)))
        }
        let owned = try fixture.file(parent.appendingPathComponent("zz.example.editor.plist"))
        let findings = await NestedFolderSource().scan(for: fixture.identity, in: fixture.root)
        #expect(findings.evidence.map(\.url) == [owned])
        #expect(findings.completeness.isComplete)
    }

    @Test func refusedParentDiscoveryIsCarriedIntoTheFootprintAndSelection() async throws {
        let fixture = Fixture()
        let denied = try fixture.folder(fixture.root.url(for: .userApplicationSupport))
        let owned = try fixture.file(fixture.root.url(for: .userCaches)
            .appendingPathComponent("SDK/zz.example.editor.plist"))
        try fixture.refuse(denied)
        let engine = EvidenceEngine(sources: [NestedFolderSource()])
        let footprint = try await FootprintProjector(engine: engine).project(
            identity: fixture.identity,
            in: fixture.root
        )
        #expect(footprint.completeness.unreadable.contains(denied.path))
        #expect(footprint.items.map(\.evidence.url) == [owned])
        let safety = SafetyEngine(safetyChecker: SafetyChecker(root: fixture.root,
                                                               brimAppURL: fixture.directory
                                                                   .appendingPathComponent("Brim.app")),
                                  vetoEngine: TierSVetoEngine(root: fixture.root))
        let evaluated = await safety.evaluate(footprint: footprint)
        #expect(evaluated.items.allSatisfy { $0.selection == .unselected })
        let intent = PlanIntent(type: .uninstall, subjectIdentity: fixture.identity)
        let plan = Planner().createPlan(from: evaluated, intent: intent, engineVersion: "test")
        #expect(plan.steps.isEmpty)
        #expect(plan.scanCompleteness == footprint.completeness)
        #expect(plan.excludedItems.first?.canBeTickedByHand == true)
        let reviewed = Planner().createPlan(from: evaluated, intent: intent.tickingByHand([owned.path]),
                                            engineVersion: "test")
        #expect(reviewed.steps.contains { $0.target == owned.path })
    }

    @Test func refusedChildrenAreReportedAndMissingRootsAreComplete() async throws {
        let fixture = Fixture()
        let denied = try fixture.folder(fixture.root.url(for: .userCaches).appendingPathComponent("SDK"))
        try fixture.refuse(denied)
        let findings = await NestedFolderSource().scan(for: fixture.identity, in: fixture.root)
        #expect(findings.completeness.unreadable == [denied.path])
        #expect(findings.completeness.timedOut.isEmpty)
        let missing = Fixture()
        let absent = await NestedFolderSource().scan(for: missing.identity, in: missing.root)
        #expect(absent.completeness.isComplete)
        #expect(absent.evidence.isEmpty)
    }

    @Test func anExpiredOrCancelledSearchReportsItsSkippedScope() async throws {
        let fixture = Fixture()
        _ = try fixture.file(fixture.root.url(for: .userCaches).appendingPathComponent("SDK/zz.example.editor.plist"))
        let expired = await NestedFolderSource(budget: { ScanBudget(total: 0) })
            .scan(for: fixture.identity, in: fixture.root)
        #expect(expired.evidence.isEmpty)
        #expect(expired.completeness.timedOut.contains(fixture.root.url(for: .userCaches).path))
        let root = fixture.root
        let identity = fixture.identity
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await NestedFolderSource().scan(for: identity, in: root)
        }.value
        #expect(cancelled.evidence.isEmpty)
        #expect(!cancelled.completeness.isComplete)
    }

    @Test func aRefusedClaimantInventoryCannotLeaveFilesAutomaticallySelected() async throws {
        let fixture = Fixture()
        let denied = try fixture.folder(fixture.root.url(for: .applications))
        try fixture.refuse(denied)
        let owned = try fixture
            .file(fixture.root.url(for: .userPreferences).appendingPathComponent("zz.example.editor.plist"))
        let item = EvaluatedItem(footprintItem: FootprintItem(
            evidence: Evidence(url: owned, tier: .B, mechanism: "Fixture", humanSentence: "Owned fixture"),
            sizeBytes: 1, capability: .ok
        ), selection: .selected, costOfError: .medium)
        let evaluated = await TierSVetoEngine(root: fixture.root).applyVeto(to: EvaluatedFootprint(
            identity: fixture.identity, items: [item]
        ))
        #expect(evaluated.completeness.unreadable.contains(denied.path))
        #expect(evaluated.items.first?.selection == .unselected)
    }

    @Test func provenanceReadFailuresAreNotReportedAsEmpty() async throws {
        let fixture = Fixture()
        let denied = try fixture.folder(fixture.root.url(for: .userLogs))
        let owned = try fixture.file(fixture.root.url(for: .userCaches).appendingPathComponent("Editor"))
        let identity = Identity(bundleID: "zz.example.editor", name: "Editor", bundlePath: "/fixture/Editor.app")
        try fixture.refuse(denied)
        let source = ProvenanceSource(readProvenance: { _ in Data([1]) })
        let findings = await source.scan(for: identity, in: fixture.root)
        #expect(findings.evidence.map(\.url) == [owned])
        #expect(findings.completeness.unreadable == [denied.path])
        let expired = await ProvenanceSource(budget: { ScanBudget(total: 0) }, readProvenance: { _ in Data([1]) })
            .scan(for: identity, in: fixture.root)
        #expect(expired.evidence.isEmpty)
        #expect(!expired.completeness.isComplete)
    }

    @Test func aSearchGapChangesTheApprovedPlanEvenWithTheSameManualSelection() throws {
        let fixture = Fixture()
        let owned = try fixture
            .file(fixture.root.url(for: .userCaches).appendingPathComponent("SDK/zz.example.editor.plist"))
        let item = EvaluatedItem(footprintItem: FootprintItem(
            evidence: Evidence(url: owned, tier: .B, mechanism: "NestedFolderSource", humanSentence: "Owned fixture"),
            sizeBytes: 1, capability: .ok
        ), selection: .unselected, costOfError: .medium)
        let intent = PlanIntent(type: .uninstall, subjectIdentity: fixture.identity).tickingByHand([owned.path])
        func plan(_ completeness: ScanCompleteness) -> Plan {
            Planner().createPlan(
                from: EvaluatedFootprint(identity: fixture.identity, items: [item], completeness: completeness),
                intent: intent,
                engineVersion: "test"
            )
        }
        let complete = plan(.complete)
        let partial = plan(ScanCompleteness(unreadable: [fixture.root.url(for: .userLogs).path]))
        #expect(complete.steps == partial.steps)
        // Hold incidental plan identity and time fixed so only the gap changes the hash.
        let sameRemoval = Plan(planId: complete.planId, createdAt: complete.createdAt,
                               engineVersion: complete.engineVersion, osVersion: complete.osVersion,
                               intent: complete.intent, steps: complete.steps, excludedItems: complete.excludedItems,
                               expectedTotalBytes: complete.expectedTotalBytes,
                               scanCompleteness: partial.scanCompleteness)
        #expect(try complete.contentHash() != sameRemoval.contentHash())
        #expect(try String(data: partial.canonicalData(), encoding: .utf8)?.contains("scanCompleteness") == true)
    }
}
