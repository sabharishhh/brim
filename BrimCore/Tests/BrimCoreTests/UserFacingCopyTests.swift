import XCTest
@testable import BrimCore

/// House style for anything a person reads.
///
/// Em and en dashes are the giveaway of text written by a model rather than
/// by someone explaining their own software, and once a few creep in the
/// whole app starts to read the same way. Every sentence Brim shows should
/// sound like a person who knows what the software does telling you plainly.
///
/// This covers the copy that lives in the model layer, where the reusable
/// sentences are. Copy in a view is caught by reading it.
final class UserFacingCopyTests: XCTestCase {

    private func assertPlain(
        _ text: String, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for dash in ["—", "–"] {
            XCTAssertFalse(
                text.contains(dash),
                "\(label) uses a \(dash): \"\(text)\"",
                file: file, line: line
            )
        }
        XCTAssertFalse(text.contains("  "), "\(label) has a double space: \"\(text)\"", file: file, line: line)
        XCTAssertFalse(text.hasSuffix(" "), "\(label) ends in a space", file: file, line: line)
    }

    func testEveryDomainSentenceReadsPlainly() {
        for domain in LeftoverDomain.allCases {
            assertPlain(domain.title, "\(domain).title")
            assertPlain(domain.whatItHolds, "\(domain).whatItHolds")
            assertPlain(domain.consequence, "\(domain).consequence")
        }
    }

    func testEveryOwnershipVerdictReadsPlainly() {
        let search = OwnershipSearch(
            installedBundleIDs: [], installedNames: [],
            receiptBundleIDs: ["com.receipt.app"],
            previouslyRemovedBundleIDs: ["com.brim.removed"],
            launchServicesLookup: { id in
                id == "com.stale.app" ? [URL(fileURLWithPath: "/Applications/Stale.app")] : []
            },
            exists: { _ in false }
        )
        for identifier in ["com.stale.app", "com.receipt.app", "com.brim.removed", "com.unknown"] {
            if case .recordedButGone(let evidence) = search.ownership(of: identifier) {
                assertPlain(evidence, "evidence for \(identifier)")
            }
        }
    }

    func testEveryApprovalPromptReadsPlainly() {
        // macOS renders these after "Brim is trying to", so they must also
        // begin in lower case and carry no trailing stop.
        func step(_ kind: StepKind, _ cost: CostOfError) -> Step {
            Step(index: 0, kind: kind, target: "/tmp/x", targetFingerprint: nil, tier: .A,
                 evidence: "e", expectedBytes: 1, capability: .ok, reversible: false,
                 costOfError: cost, executionPhase: .auxiliary, disposition: .delete)
        }
        let cases: [[Step]] = [
            [step(.trashPath, .medium)],
            [step(.trashPath, .medium), step(.trashPath, .high)],
            [step(.resetPrivacyGrants, .medium)],
            [step(.resetPrivacyGrants, .medium), step(.trashPath, .high)]
        ]
        for steps in cases {
            let plan = Plan(
                planId: UUID(), createdAt: Date(), engineVersion: "t", osVersion: "t",
                intent: PlanIntent(type: .uninstall,
                                   subjectIdentity: Identity(bundleID: "com.t.a", name: "Thing")),
                steps: steps, excludedItems: [], expectedTotalBytes: 1
            )
            guard case .humanPresence(let reason) = ApprovalPolicy()
                .requirement(for: plan, lastAuthenticated: nil) else { continue }
            assertPlain(reason, "approval reason")
            XCTAssertEqual(reason.first?.isLowercase, true, "\"\(reason)\" follows \"Brim is trying to\"")
            XCTAssertFalse(reason.hasSuffix("."), "macOS supplies the full stop: \"\(reason)\"")
        }
    }
}
