import XCTest
@testable import BrimCore

/// Tier S is a veto, and only a veto.
///
/// The letters disagreed with the specification in the dangerous
/// direction. `EvidenceTier.S` meant "cryptographically guaranteed" in the
/// code and mapped to selected, while T-1.9 and T-3.4 define S as Shared:
/// the one-way control that may take an item out of a selection and never
/// put one in. Anybody following the specification and writing `tier: .S`
/// to protect a shared component would have marked it for removal.
///
/// It never fired only because no source emitted `.S`. That is not a
/// safety property, it is an accident of coverage, so these hold it.
final class TierSVetoTests: XCTestCase {

    private func evaluate(tier: EvidenceTier, path: String = "/tmp/brim-tier-test/thing") async -> EvaluatedItem {
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/tmp/brim-tier-test"))
        let engine = SafetyEngine(
            safetyChecker: SafetyChecker(
                root: root, brimAppURL: URL(fileURLWithPath: "/tmp/brim-tier-test/Brim.app")
            ),
            vetoEngine: TierSVetoEngine(root: root)
        )
        let item = FootprintItem(
            evidence: Evidence(
                url: URL(fileURLWithPath: path), tier: tier,
                mechanism: "test", humanSentence: "because"
            ),
            sizeBytes: 1, capability: .ok
        )
        let result = await engine.evaluate(
            footprint: Footprint(
                identity: Identity(bundleID: "com.example.app", name: "Example"), items: [item]
            )
        )
        return result.items[0]
    }

    func testSharedIsNeverSelected() async {
        let evaluated = await evaluate(tier: .S)
        guard case .excluded(let reason) = evaluated.selection else {
            return XCTFail("Tier S produced \(evaluated.selection). It may only ever exclude.")
        }
        XCTAssertFalse(reason.isEmpty, "An exclusion has to say why")
    }

    func testTheOtherTiersStillBehave() async {
        if case .selected = await evaluate(tier: .A).selection {} else {
            XCTFail("Tier A should still be selected by default")
        }
        if case .selected = await evaluate(tier: .B).selection {} else {
            XCTFail("Tier B should still be selected by default")
        }
        if case .unselected = await evaluate(tier: .C).selection {} else {
            XCTFail("Tier C is shown, not selected")
        }
    }

    /// T-3.4's acceptance criterion: no code path lets Tier S select.
    ///
    /// Read from the source rather than exercised, because the failure
    /// this guards against is a future branch that nobody thought to write
    /// a case for.
    func testNoCodePathMapsSharedToSelected() throws {
        let engine = Self.repositoryRoot()
            .appendingPathComponent("BrimCore/Sources/BrimCore/Safety/SafetyEngine.swift")
        let text = try String(contentsOf: engine, encoding: .utf8)

        // The `case .S:` arm, up to the next case label.
        guard let start = text.range(of: "case .S:") else {
            return XCTFail("SafetyEngine no longer decides anything for Tier S")
        }
        let rest = text[start.upperBound...]
        let arm = rest.range(of: "case .").map { String(rest[..<$0.lowerBound]) } ?? String(rest)

        XCTAssertTrue(arm.contains(".excluded"), "Tier S must exclude: \(arm)")
        XCTAssertFalse(arm.contains(".selected"), "Tier S reached a selection: \(arm)")
        XCTAssertFalse(arm.contains(".unselected"),
                       "Unselected is not excluded. A person can tick an unselected box.")
    }

    func testSharedIsNotOnTheConfidenceScale() {
        // Anything that ranks or compares how sure Brim is has to leave S
        // out. It is a claim about another application, not about this one.
        XCTAssertFalse(EvidenceTier.S.isConfidence)
        for tier in EvidenceTier.allCases where tier != .S {
            XCTAssertTrue(tier.isConfidence, "\(tier) is a confidence level")
        }
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}
