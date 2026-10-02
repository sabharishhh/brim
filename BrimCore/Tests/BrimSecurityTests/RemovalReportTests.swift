@testable import BrimCore
@testable import BrimProtocol
@testable import BrimService
import XCTest

// swiftformat:disable wrapMultilineStatementBraces
/// The report after a removal keeps three facts apart: checked and gone,
/// declared none by the app, and kept by macOS. One sentence used to cover
/// all three, which is how a removal claims more than it checked.
final class RemovalReportTests: XCTestCase {
    private func step(_ index: Int, _ target: String) -> Step {
        Step(index: index, kind: .trashPath, target: target, targetFingerprint: nil, tier: .A,
             evidence: "", expectedBytes: 1, capability: .ok, reversible: true, costOfError: .low)
    }

    private func check(
        _ capability: DeclaredCapability, _ declaration: CapabilitySurface.DeclarationState,
        available: Bool = true, absence: RegistrationCoverage.Absence? = nil,
        found: [String] = [], tier: RemovalTier? = nil
    ) -> CapabilitySearchReport.Check {
        CapabilitySearchReport.Check(
            capability: capability, declaration: declaration,
            coverage: RegistrationCoverage(kind: capability.registrationKind, available: available,
                                           limitation: available ? nil : "Could not read.", absence: absence),
            registrations: found.map {
                Registration(kind: capability.registrationKind, identifier: $0, label: $0,
                             targetExists: true, evidence: "")
            },
            removalTier: tier
        )
    }

    private func plan(_ steps: [Step], checks: [CapabilitySearchReport.Check] = [],
                      excluded: [ExcludedItem] = []) -> Plan {
        Plan(planId: UUID(), createdAt: Date(), engineVersion: "t", osVersion: "t",
             intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: "com.x.app", name: "X")),
             steps: steps, excludedItems: excluded, expectedTotalBytes: 0)
            .attaching(checks.isEmpty ? nil : CapabilitySearchReport(checks: checks, signatureCoverage: []))
    }

    func testAPathIsGoneKeptByMacOSOrStillThereAndNeverTwo() {
        let subject = plan([step(0, "/u/Library/Caches/x"), step(1, "/u/Library/Prefs/x.plist"),
                            step(2, "/Library/Protected/x"), step(3, "/u/Library/App/x")])
        let report = RemovalReport.build(
            plan: subject,
            remaining: ["/u/Library/Prefs/x.plist", "/Library/Protected/x", "/u/Library/App/x"],
            // Written back by the app after it went: still there, not macOS's doing.
            recorded: ["/u/Library/Prefs/x.plist": "ok", "/u/Library/App/x": "refusedByOS"],
            staleRegistrations: 0, privacyResetFailed: false, survivingExtensions: nil,
            capability: { $0.hasPrefix("/Library/Protected") ? .refusedByOS : .ok }
        )
        XCTAssertEqual(report.checkedGone, 1)
        XCTAssertEqual(report.stillThere, 1)
        XCTAssertEqual(report.keptByMacOS.count, 2)
        XCTAssertEqual(report.checkedGone + report.stillThere + report.keptByMacOS.count, 4)
    }

    func testDeclaredNoneIsNotCountedAsChecked() {
        let subject = plan([], checks: [
            check(.systemExtension, .notDeclared),
            check(.launchdJob, .declared, found: ["com.x.app.helper"], tier: .removable),
            check(.privilegedHelper, .unknown)
        ])
        let report = RemovalReport.build(plan: subject, remaining: [], recorded: [:], staleRegistrations: 0,
                                         privacyResetFailed: false, survivingExtensions: nil)
        XCTAssertEqual(report.declaredNone, [.systemExtension])
        XCTAssertTrue(report.registrationsChecked.isEmpty, "A preflight scan is not a post-removal check.")
        XCTAssertTrue(report.keptByMacOS.isEmpty)
    }

    /// Did not look is not nothing found, and a boundary Brim keeps on
    /// purpose is not macOS refusing.
    func testWhatCouldNotBeReadIsKeptAndABoundaryIsLeftOut() {
        let subject = plan([], checks: [
            check(.privacyGrant, .declared, available: false, absence: .needsPermission),
            check(.vpnConfiguration, .declared, available: false, absence: .byDesign)
        ])
        let report = RemovalReport.build(plan: subject, remaining: [], recorded: [:], staleRegistrations: 0,
                                         privacyResetFailed: false, survivingExtensions: nil)
        XCTAssertTrue(report.keptByMacOS.isEmpty, "An unreadable surface is unknown, not a known retained grant.")
        XCTAssertTrue(report.registrationsChecked.isEmpty)
        XCTAssertTrue(report.declaredNone.isEmpty)
    }

    func testOnlyFreshCompleteObservationsCertifyRegistrationAbsence() {
        let subject = plan(
            [],
            checks: [check(.systemExtension, .declared, found: ["com.x.ext"], tier: .detectableOnly)]
        )
        let fresh = RegistrationVerification(capability: .systemExtension, observedAt: Date(),
                                             coverage: .available(.systemExtension), remaining: [])
        let gone = RemovalReport.build(plan: subject, remaining: [], recorded: [:], staleRegistrations: 0,
                                       privacyResetFailed: false, survivingExtensions: [],
                                       registrationObservations: [fresh])
        XCTAssertEqual(gone.registrationsChecked, [.systemExtension])
        let unknown = RegistrationVerification(capability: .systemExtension, observedAt: Date(),
                                               coverage: .unavailable(.systemExtension, "Could not read."),
                                               remaining: [])
        let report = RemovalReport.build(plan: subject, remaining: [], recorded: [:], staleRegistrations: 0,
                                         privacyResetFailed: false, survivingExtensions: [],
                                         registrationObservations: [unknown])
        XCTAssertTrue(report.registrationsChecked.isEmpty)
        XCTAssertTrue(report.registrationObservations?.first?.couldNotCheck == true)
        XCTAssertTrue(report.keptByMacOS.isEmpty)
    }

    func testUnknownPathDoesNotCountAsGoneOrObservedPresent() {
        let report = RemovalReport.build(plan: plan([step(0, "/unknown")]), remaining: ["/unknown"], recorded: [:],
                                         staleRegistrations: 0, privacyResetFailed: false, survivingExtensions: nil,
                                         unknownPaths: ["/unknown"], registrationObservations: [])
        XCTAssertEqual(report.checkedGone, 0)
        XCTAssertEqual(report.stillThere, 0)
        XCTAssertEqual(report.unknownPaths, ["/unknown"])
    }

    func testRegistrationsMacOSKeptAreReported() {
        let report = RemovalReport.build(plan: plan([]), remaining: [], recorded: [:], staleRegistrations: 1,
                                         privacyResetFailed: true, survivingExtensions: nil)
        XCTAssertEqual(report.keptByMacOS.map(\.what), ["File and URL associations", "Privacy permissions"])
    }

    /// WhatsApp's bundle was never moved, and the result said Brim had
    /// removed it and something wrote it back: the retraction of its Launch
    /// Services record shares the path and its "ok" was read instead.
    func testTheStepThatMovesAPathExplainsIt() {
        let app = "/Applications/WhatsApp.app"
        let subject = Plan(
            planId: UUID(), createdAt: Date(), engineVersion: "t", osVersion: "t",
            intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: "net.w", name: "W")),
            steps: [
                Step(index: 1, kind: .trashPathPrivileged, target: app, targetFingerprint: nil, tier: .A, evidence: "",
                     expectedBytes: 1, capability: .needsHelper, reversible: true, costOfError: .low,
                     executionPhase: .appBundle),
                Step(index: 22, kind: .unregisterLaunchServices, target: app, targetFingerprint: nil, tier: .A,
                     evidence: "", expectedBytes: 0, capability: .ok, reversible: false, costOfError: .low,
                     executionPhase: .registration)
            ], excludedItems: [], expectedTotalBytes: 1
        )
        let journal = JournalEntry(planId: subject.planId, startedAt: Date(), status: .partial,
                                   stepOutcomes: [1: "skipped_due_to_prior_failures", 22: "ok"])
        XCTAssertEqual(BrimService.recordedOutcomes(plan: subject, journal: journal, remaining: [app])[app],
                       "skipped_due_to_prior_failures")
    }

    /// Antigravity's removal said "Nothing left" while four name matches the
    /// person had not ticked were still on the disk. The report names them,
    /// and leaves out a vetoed item and one that has since gone.
    func testUntickedItemsStillOnDiskAreReported() throws {
        let subject = plan([step(0, "/u/Library/Caches/x")], excluded: [
            ExcludedItem(target: "/u/.x-ide", reason: "", canBeTickedByHand: true, tier: .C),
            ExcludedItem(target: "/u/.cache/x", reason: "", canBeTickedByHand: true, tier: .C),
            ExcludedItem(target: "/u/Library/Group Containers/shared", reason: "", canBeTickedByHand: false)
        ])
        let report = RemovalReport.build(
            plan: subject, remaining: [], recorded: [:], staleRegistrations: 0,
            privacyResetFailed: false, survivingExtensions: nil, capability: { _ in .ok },
            exists: { $0 != "/u/.cache/x" }
        )
        XCTAssertEqual(report.leftUnticked, ["/u/.x-ide"])

        // A report saved before the field existed still decodes.
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        json.removeValue(forKey: "leftUnticked")
        let old = try JSONDecoder().decode(RemovalReport.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.leftUnticked, [])
    }
}
