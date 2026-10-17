@testable import BrimCore
import XCTest

/// A row Brim found but did not tick, ticked by the person in the uninstall
/// sheet. The choice travels on the intent, so it is approved and rebuilt
/// with the plan. It can only promote a row the engine found and left
/// unticked, cannot bring back a vetoed row, and cannot add a path the
/// engine did not find.
final class TickedByHandPlannerTests: XCTestCase {
    private var directory: URL!
    private let fileManager = FileManager.default
    private let identity = Identity(bundleID: "com.example.editor", name: "Editor", bundleName: "Studio")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ticked-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: directory)
    }

    private func file(_ name: String, bytes: Int = 64) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    private func row(
        _ url: URL, _ selection: SelectionState, tier: EvidenceTier = .C, bytes: Int64 = 64,
        sentence: String = "Named after the name the application gives itself"
    ) -> EvaluatedItem {
        EvaluatedItem(
            footprintItem: FootprintItem(
                evidence: Evidence(url: url, tier: tier, mechanism: "Test", humanSentence: sentence),
                sizeBytes: bytes, capability: .ok
            ),
            selection: selection, costOfError: .medium
        )
    }

    private func plan(_ rows: [EvaluatedItem], ticked: [String]? = nil) -> Plan {
        Planner().createPlan(
            from: EvaluatedFootprint(identity: identity, items: rows),
            intent: PlanIntent(type: .uninstall, subjectIdentity: identity, tickedByHand: ticked),
            engineVersion: "test"
        )
    }

    private func stepTargets(_ plan: Plan) -> Set<String> {
        Set(plan.steps.filter(\.kind.targetIsPath).map(\.target))
    }

    // MARK: - What a tick does

    /// Found, left unticked as a name match, and the person wants it gone.
    func testARowTheEngineFoundButDidNotTickIsRemovedWhenThePersonTicksIt() throws {
        let support = try file("Studio", bytes: 4096)

        let untouched = plan([row(support, .unselected)])
        XCTAssertFalse(stepTargets(untouched).contains(support.path), "Ticked with nobody asking.")

        let ticked = plan([row(support, .unselected)], ticked: [support.path])
        XCTAssertTrue(
            stepTargets(ticked).contains(support.path),
            "The person ticked a row Brim found and it is not in the plan."
        )
        XCTAssertFalse(
            ticked.excludedItems.contains { $0.target == support.path },
            "The ticked row is being removed and is still listed as kept."
        )
    }

    // MARK: - What a tick cannot do

    /// Tier S is one way: a vetoed row cannot be ticked back in.
    func testAVetoedRowCannotBeTickedBackIn() throws {
        let shared = try file("UBF8T346G9.com.microsoft.teams")
        let refused = try file("protected-by-safety")

        let planned = plan(
            [
                row(shared, .excluded(reason: "Shared with other installed software."), tier: .S),
                row(refused, .excluded(reason: "Brim refused to modify this item to ensure system stability."))
            ],
            ticked: [shared.path, refused.path]
        )

        XCTAssertTrue(
            stepTargets(planned).isDisjoint(with: [shared.path, refused.path]),
            "A vetoed row was put back into the plan because the intent named it."
        )
        for path in [shared.path, refused.path] {
            let kept = planned.excludedItems.first { $0.target == path }
            XCTAssertNotNil(kept, "\(path) disappeared from the plan entirely.")
            XCTAssertEqual(kept?.canBeTickedByHand, false, "\(path) is offered as tickable.")
        }
    }

    /// A tick only promotes a row the engine found for this application. Other
    /// paths go through explicit targets and their own review.
    func testTickingByHandCannotAddAPathTheEngineDidNotFind() throws {
        let support = try file("Studio")
        let thesis = try file("Thesis.md")

        let planned = plan([row(support, .unselected)], ticked: [support.path, thesis.path])

        XCTAssertTrue(stepTargets(planned).contains(support.path))
        XCTAssertFalse(
            stepTargets(planned).contains(thesis.path),
            "A document the engine never found was added to an uninstall by naming it."
        )
        XCTAssertTrue(fileManager.fileExists(atPath: thesis.path))
    }

    // MARK: - What the sheet needs to offer it

    /// An unticked row carries what a step carries: its evidence and its size.
    /// A vetoed row says it cannot be ticked.
    func testAnUntickedRowSaysItCanBeTickedAndWhatItHolds() throws {
        let support = try file("Studio", bytes: 4096)
        let shared = try file("shared")

        let planned = plan([
            row(support, .unselected, bytes: 131_500_000),
            row(shared, .excluded(reason: "Shared with other installed software."), tier: .S)
        ])

        let offered = try XCTUnwrap(planned.excludedItems.first { $0.target == support.path })
        XCTAssertEqual(offered.canBeTickedByHand, true)
        XCTAssertEqual(offered.sizeBytes, 131_500_000)
        XCTAssertEqual(offered.tier, .C)
        XCTAssertEqual(
            offered.evidence?.hasPrefix("Named after the name the application gives itself"), true,
            "The row does not say how Brim knows it belongs to this application."
        )

        let vetoed = try XCTUnwrap(planned.excludedItems.first { $0.target == shared.path })
        XCTAssertEqual(vetoed.canBeTickedByHand, false)
    }

    // MARK: - Approval

    /// The intent is part of the plan's hash, which the approval token is bound
    /// to, so ticking after approval changes the plan.
    func testThePersonsChoiceIsPartOfWhatIsApproved() throws {
        let support = try file("Studio")
        let planned = plan([row(support, .unselected)], ticked: [support.path])

        let canonical = try XCTUnwrap(try String(data: planned.canonicalData(), encoding: .utf8))
        XCTAssertTrue(
            canonical.contains("\"tickedByHand\":[\"\(support.path)\"]"),
            "The ticked rows are not in the data an approval is bound to."
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let without = try encoder.encode(PlanIntent(type: .uninstall, subjectIdentity: identity))
        let with = try encoder.encode(
            PlanIntent(type: .uninstall, subjectIdentity: identity, tickedByHand: [support.path])
        )
        XCTAssertNotEqual(without, with)
    }

    /// A stored plan from before this field still decodes, and an old excluded
    /// row is not offered.
    func testAPlanWrittenBeforeThisStillDecodes() throws {
        let oldIntent = """
        {"type":"uninstall","subjectIdentity":{"name":"Editor","isSandboxed":false,"groupContainers":[]},\
        "requesterKind":"ui","requesterIdentity":"user","archiveAndUninstall":false}
        """
        let intent = try JSONDecoder().decode(PlanIntent.self, from: Data(oldIntent.utf8))
        XCTAssertNil(intent.tickedByHand)

        let oldExcluded = #"{"target":"/x","reason":"You opted to keep this item."}"#
        let excluded = try JSONDecoder().decode(ExcludedItem.self, from: Data(oldExcluded.utf8))
        XCTAssertNil(excluded.canBeTickedByHand)
        XCTAssertNil(excluded.sizeBytes)
    }

    /// An intent that ticks nothing encodes and hashes as before.
    func testAnIntentThatTicksNothingEncodesAsItAlwaysDid() throws {
        let data = try JSONEncoder().encode(PlanIntent(type: .uninstall, subjectIdentity: identity))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("tickedByHand"))
    }
}
