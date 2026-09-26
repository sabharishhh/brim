import XCTest
@testable import BrimCore

/// A row Brim found but did not tick, ticked by the person in the uninstall
/// sheet.
///
/// "An unfinished search selects nothing. Everything found is still shown and
/// every row can still be ticked by hand." The second half of that was not
/// true of the uninstall sheet: it listed what the plan would remove and
/// nothing else, so a row Brim left unticked could not be ticked at all.
/// Visual Studio Code's 131.5 MB `Application Support/Code` was found, named,
/// and impossible to remove, and rating a name match Tier C everywhere, as
/// the inventory's rule says, would have done the same to Claude's 11 GB.
///
/// The person's choice travels on the intent, so it is part of what they
/// approve and part of what `apply` rebuilds when it checks the plan again.
/// Three things keep it from being a way round the evidence engine, and each
/// has a test here: it can only promote a row the engine found and left
/// unticked; it cannot bring back a row that was vetoed, which is how Tier S
/// stays one way; and it cannot add a path the engine did not find at all.
final class TickedByHandPlannerTests: XCTestCase {

    private var directory: URL!
    private let fm = FileManager.default
    private let identity = Identity(bundleID: "com.example.editor", name: "Editor", bundleName: "Studio")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ticked-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: directory)
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
        Set(plan.steps.filter { $0.kind.targetIsPath }.map(\.target))
    }

    // MARK: - What a tick does

    /// **Application Support/Code.** Found, left unticked because it is
    /// matched on a name, and the person wants it gone.
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

    /// **Tier S is one way.** A row something else on this Mac claims was
    /// taken out of the selection and cannot re-enter it, however it is
    /// asked for. Microsoft Teams' group container does not come back into
    /// Visual Studio Code's uninstall because a list names it.
    func testAVetoedRowCannotBeTickedBackIn() throws {
        let shared = try file("UBF8T346G9.com.microsoft.teams")
        let refused = try file("protected-by-safety")

        let planned = plan(
            [
                row(shared, .excluded(reason: "Shared with other installed software."), tier: .S),
                row(refused, .excluded(reason: "Brim refused to modify this item to ensure system stability.")),
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

    /// **The uninstall stays identity-driven.** A tick can only promote a row
    /// the evidence engine found for this application. A path it did not
    /// find, however it arrives, is not a way to have an uninstall remove
    /// something else: that is what explicit targets are for, and they go
    /// through their own sheet and their own review.
    func testTickingByHandCannotAddAPathTheEngineDidNotFind() throws {
        let support = try file("Studio")
        let thesis = try file("Thesis.md")

        let planned = plan([row(support, .unselected)], ticked: [support.path, thesis.path])

        XCTAssertTrue(stepTargets(planned).contains(support.path))
        XCTAssertFalse(
            stepTargets(planned).contains(thesis.path),
            "A document the engine never found was added to an uninstall by naming it."
        )
        XCTAssertTrue(fm.fileExists(atPath: thesis.path))
    }

    // MARK: - What the sheet needs to offer it

    /// The sheet can only offer a row it can describe, so an unticked row
    /// carries what a step carries: what Brim knows about it, and how much it
    /// holds. A vetoed row is described too, and says it cannot be ticked.
    func testAnUntickedRowSaysItCanBeTickedAndWhatItHolds() throws {
        let support = try file("Studio", bytes: 4096)
        let shared = try file("shared")

        let planned = plan([
            row(support, .unselected, bytes: 131_500_000),
            row(shared, .excluded(reason: "Shared with other installed software."), tier: .S),
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

    /// The choice is part of the intent, and the intent is part of the plan's
    /// hash, which is what an approval token is bound to. Ticking a row after
    /// approval changes the plan the token was minted for.
    func testThePersonsChoiceIsPartOfWhatIsApproved() throws {
        let support = try file("Studio")
        let planned = plan([row(support, .unselected)], ticked: [support.path])

        let canonical = try XCTUnwrap(String(data: try planned.canonicalData(), encoding: .utf8))
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

    /// Plans are stored, and a plan written before this existed has neither
    /// the intent's field nor the excluded row's. Both still decode, and an
    /// old excluded row is simply not offered.
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

    /// An intent that ticks nothing encodes exactly as it did before, so
    /// every plan made without the sheet's help hashes as it always has.
    func testAnIntentThatTicksNothingEncodesAsItAlwaysDid() throws {
        let data = try JSONEncoder().encode(PlanIntent(type: .uninstall, subjectIdentity: identity))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("tickedByHand"))
    }
}
