import XCTest
import BrimCore
import BrimProtocol
import BrimOps
@testable import BrimService

/// The product promise, measured: uninstalling by identity alone must find
/// and remove the whole footprint, leaving nothing for a later scan to find.
///
/// Nothing here names a path to remove. The identity goes in, the evidence
/// engine discovers the footprint, and the test asserts on what came back —
/// so a source that stops working shows up as a named gap rather than as a
/// quietly shallower uninstall.
final class DeepUninstallTests: XCTestCase {

    private var fixture = RealEnvironmentFixture()
    private var supportDirectory: URL!

    override func setUpWithError() throws {
        try RealEnvironmentFixture.requireEnabled(self)
        fixture = RealEnvironmentFixture()
        supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrimHarnessStore-\(UUID().uuidString)")
    }

    override func tearDown() {
        fixture.cleanUp()
        if let supportDirectory {
            try? FileManager.default.removeItem(at: supportDirectory)
        }
        super.tearDown()
    }

    private func makeService() -> BrimService {
        BrimService(
            root: FileSystemRoot(rootURL: URL(fileURLWithPath: "/")),
            brimAppURL: Bundle.main.bundleURL,
            planStoreDirectory: supportDirectory.appendingPathComponent("Plans"),
            journalStoreDirectory: supportDirectory.appendingPathComponent("Journals")
        )
    }

    /// Discovery coverage: which parts of a scattered footprint does the
    /// evidence engine actually find from the identity alone?
    func testUninstallByIdentityDiscoversTheWholeFootprint() async throws {
        let footprint = try fixture.makeAppFootprint()
        let identity = Identity(bundleID: fixture.harnessBundleID, name: fixture.harnessBundleID)

        let service = makeService()
        let plan = try await service.plan(
            intent: PlanIntent(
                type: .uninstall,
                subjectIdentity: identity,
                requesterKind: "harness",
                requesterIdentity: NSUserName()
            )
        )

        let planned = Set(plan.steps.map { URL(fileURLWithPath: $0.target).standardizedFileURL.path })
        let missed = footprint.filter { !planned.contains($0.url.standardizedFileURL.path) }

        XCTAssertTrue(
            missed.isEmpty,
            """
            Deep uninstall missed \(missed.count) of \(footprint.count) footprint locations.
            Not discovered: \(missed.map(\.label).sorted().joined(separator: ", "))
            These would survive an uninstall and reappear later as leftovers.
            """
        )
    }

    /// The promise end to end: after Brim uninstalls, a fresh scan of the
    /// same identity finds nothing left.
    func testNothingSurvivesAnUninstall() async throws {
        let footprint = try fixture.makeAppFootprint()
        let identity = Identity(bundleID: fixture.harnessBundleID, name: fixture.harnessBundleID)
        let service = makeService()

        let intent = PlanIntent(
            type: .uninstall,
            subjectIdentity: identity,
            requesterKind: "harness",
            requesterIdentity: NSUserName()
        )

        let plan = try await service.plan(intent: intent)
        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
        try await service.apply(planId: plan.planId, token: token)

        let survivors = footprint.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if !survivors.isEmpty {
            // Say *why* each one survived, so the failure names the defect
            // rather than only its symptom.
            let journal = try await JournalStore(directoryURL: supportDirectory.appendingPathComponent("Journals"))
                .load(planId: plan.planId)
            // A target can legitimately carry several steps (a launchd job is
            // unloaded and then its plist removed), so group rather than map.
            let byTarget = Dictionary(grouping: plan.steps, by: \.target)
            let detail = survivors.map { survivor -> String in
                let path = survivor.url.standardizedFileURL.path
                let steps = byTarget[path] ?? byTarget[survivor.url.path] ?? []
                guard !steps.isEmpty else {
                    let excluded = plan.excludedItems.first { $0.target == path }
                    return "\(survivor.label): no step planned (\(excluded?.reason ?? "not in plan"))"
                }
                let outcomes = steps.map { step in
                    "step \(step.index) \(step.kind) → \(journal?.stepOutcomes[step.index] ?? "no journal entry")"
                }
                return "\(survivor.label): " + outcomes.joined(separator: "; ")
            }
            XCTFail("Left behind:\n  " + detail.joined(separator: "\n  "))
        }

        // The strongest form of the claim: ask the engine again and it finds
        // nothing, so a later scan cannot surface this app as a leftover.
        let residual = try await service.inspect(identity: identity)
        XCTAssertTrue(
            residual.items.isEmpty,
            "A re-scan still attributes \(residual.items.count) items to an app Brim just uninstalled: "
            + residual.items.map { $0.evidence.url.lastPathComponent }.joined(separator: ", ")
        )
    }

    /// Removing the files is not the whole uninstall. Launch Services keeps
    /// its own record of an application — the one behind "Open With" and the
    /// document types it claims — and deleting the bundle does not retract
    /// it. This test exists because the first real uninstall Brim performed
    /// reported "nothing remains" while eight such records survived.
    func testTheLaunchServicesRegistrationDoesNotSurviveAnUninstall() async throws {
        let bundle = try fixture.makeRegisteredAppBundle()
        _ = try fixture.makeAppFootprint()
        let identity = Identity(bundleID: fixture.harnessBundleID, name: fixture.runID)

        // The premise: the harness bundle really is registered beforehand,
        // otherwise this test would pass without proving anything.
        XCTAssertFalse(
            LaunchServicesRegistration.registeredApplicationURLs(forBundleID: fixture.harnessBundleID).isEmpty,
            "Harness bundle was never registered, so this test proves nothing"
        )

        let service = makeService()
        let intent = PlanIntent(
            type: .uninstall,
            subjectIdentity: identity,
            requesterKind: "harness",
            requesterIdentity: NSUserName()
        )

        let plan = try await service.plan(intent: intent)
        XCTAssertTrue(
            plan.steps.contains { $0.kind == .unregisterLaunchServices },
            "An uninstall of an installed .app must plan to retract its registration"
        )

        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
        try await service.apply(planId: plan.planId, token: token)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bundle.path),
            "The bundle itself should be gone"
        )
        XCTAssertEqual(
            LaunchServicesRegistration.registeredApplicationURLs(forBundleID: fixture.harnessBundleID),
            [],
            "macOS still has the removed app registered"
        )

        // And the product's own claim agrees with the machine.
        let verification = try await service.verify(planId: plan.planId)
        XCTAssertTrue(verification.success, verification.reason ?? "")
    }

    /// The claim has to be falsifiable: if a registration survives,
    /// verification must say so rather than reporting success.
    ///
    /// This recreates the exact state the first real uninstall left behind —
    /// bundle gone from disk, Launch Services still pointing at where it was
    /// — by removing the bundle with FileManager, which is what every tool
    /// that does not know about this surface effectively does.
    func testVerificationFailsWhileARegistrationSurvives() async throws {
        _ = try fixture.makeRegisteredAppBundle()
        _ = try fixture.makeAppFootprint()
        let identity = Identity(bundleID: fixture.harnessBundleID, name: fixture.runID)

        let service = makeService()
        let plan = try await service.plan(intent: PlanIntent(
            type: .uninstall,
            subjectIdentity: identity,
            requesterKind: "harness",
            requesterIdentity: NSUserName()
        ))
        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
        try await service.apply(planId: plan.planId, token: token)

        // Clean first, so the failure below can only come from the
        // registration.
        let clean = try await service.verify(planId: plan.planId)
        XCTAssertTrue(clean.success, clean.reason ?? "")

        // Put the bundle back at the same path, let Launch Services record
        // it, then delete it the naive way — leaving the record behind.
        let bundle = try fixture.makeRegisteredAppBundle()
        guard !LaunchServicesRegistration
            .registeredApplicationURLs(forBundleID: fixture.harnessBundleID).isEmpty else {
            throw XCTSkip("Launch Services did not register the replanted bundle")
        }
        try FileManager.default.removeItem(at: bundle)
        guard LaunchServicesRegistration
            .registeredApplicationURLs(forBundleID: fixture.harnessBundleID)
            .contains(where: { $0.standardizedFileURL.path == bundle.standardizedFileURL.path }) else {
            throw XCTSkip("Launch Services dropped the record on its own; nothing stale to detect")
        }

        let verification = try await service.verify(planId: plan.planId)
        if verification.success {
            // Launch Services is a live database that prunes records for
            // files that have gone. If it dropped this one between planting
            // it and the check, the premise no longer holds and there is
            // nothing to assert — that is a skip, not a pass and not a
            // failure.
            try XCTSkipIf(
                LaunchServicesRegistration
                    .registeredApplicationURLs(forBundleID: fixture.harnessBundleID).isEmpty,
                "Launch Services pruned the planted record before verification ran"
            )
        }
        XCTAssertFalse(verification.success, "A surviving registration is not 'nothing remains'")
        XCTAssertEqual(verification.reason?.contains("still has this app registered"), true,
                       "The reason should name what survived, got: \(verification.reason ?? "nil")")

        try? LaunchServicesRegistration.unregister(bundlePath: bundle.path)
    }

    /// A second copy of the same application, somewhere Brim did not touch,
    /// is not a leftover of this uninstall. Without scoping, this check would
    /// fire on any machine holding two copies of an app.
    func testAnotherCopyOfTheAppIsNotReportedAsALeftover() async throws {
        _ = try fixture.makeRegisteredAppBundle()
        _ = try fixture.makeAppFootprint()
        let identity = Identity(bundleID: fixture.harnessBundleID, name: fixture.runID)

        let service = makeService()
        let plan = try await service.plan(intent: PlanIntent(
            type: .uninstall,
            subjectIdentity: identity,
            requesterKind: "harness",
            requesterIdentity: NSUserName()
        ))
        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
        try await service.apply(planId: plan.planId, token: token)

        let other = try fixture.makeRegisteredAppBundle(suffix: "-othercopy")
        guard !LaunchServicesRegistration
            .registeredApplicationURLs(forBundleID: fixture.harnessBundleID).isEmpty else {
            throw XCTSkip("Launch Services did not register the second copy")
        }

        let verification = try await service.verify(planId: plan.planId)
        XCTAssertTrue(
            verification.success,
            "A copy at \(other.path) that Brim never removed is not this uninstall's leftover: "
            + (verification.reason ?? "")
        )
    }

    /// Where the bundle went is not a leftover. A trashed app keeps its
    /// name, so Launch Services registers it in the Trash — exactly as it
    /// does for any app dragged there by hand. The app is recoverable and
    /// the record says so; calling that a leftover would mean fighting the
    /// OS and racing its daemon. What must be gone is the record for the
    /// path the app was *installed* at.
    func testTheInstalledPathIsUnregisteredEvenWhenTheBundleIsOnlyTrashed() async throws {
        let bundle = try fixture.makeRegisteredAppBundle()
        _ = try fixture.makeAppFootprint()
        let identity = Identity(bundleID: fixture.harnessBundleID, name: fixture.runID)

        let service = makeService()
        let plan = try await service.plan(intent: PlanIntent(
            type: .uninstall,
            subjectIdentity: identity,
            requesterKind: "harness",
            requesterIdentity: NSUserName()
        ))
        let bundleStep = try XCTUnwrap(plan.steps.first { $0.executionPhase == .appBundle })
        try XCTSkipUnless(bundleStep.effectiveDisposition == .trash,
                          "This test is about the Trash path specifically")

        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
        try await service.apply(planId: plan.planId, token: token)

        let stillAtInstalledPath = LaunchServicesRegistration
            .registeredApplicationURLs(forBundleID: fixture.harnessBundleID)
            .filter { $0.standardizedFileURL.path == bundle.standardizedFileURL.path }
        XCTAssertEqual(stillAtInstalledPath, [], "The installed path must not stay registered")

        let verification = try await service.verify(planId: plan.planId)
        XCTAssertTrue(verification.success, verification.reason ?? "")
    }

    /// Undo has to put the registration back with the files. Restoring a
    /// working application that macOS no longer knows about is its own kind
    /// of broken.
    func testUndoRestoresTheRegistration() async throws {
        let bundle = try fixture.makeRegisteredAppBundle()
        _ = try fixture.makeAppFootprint()
        let identity = Identity(bundleID: fixture.harnessBundleID, name: fixture.runID)

        let service = makeService()
        let plan = try await service.plan(intent: PlanIntent(
            type: .uninstall,
            subjectIdentity: identity,
            requesterKind: "harness",
            requesterIdentity: NSUserName()
        ))
        try XCTSkipUnless(plan.isReversible, "Nothing to undo if the plan was permanent")

        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
        try await service.apply(planId: plan.planId, token: token)
        XCTAssertEqual(
            LaunchServicesRegistration.registeredApplicationURLs(forBundleID: fixture.harnessBundleID),
            []
        )

        try await service.undo(planId: plan.planId)

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path), "The bundle should be back")
        XCTAssertTrue(
            LaunchServicesRegistration
                .registeredApplicationURLs(forBundleID: fixture.harnessBundleID)
                .contains { $0.standardizedFileURL.path == bundle.standardizedFileURL.path },
            "A restored application macOS does not know about has no document types and no Open With"
        )
    }

    /// Emptying the Trash is what turns an accurate registration into a
    /// stale one, and macOS does not reliably prune it — a record for a
    /// bundle that had already gone from the Trash was observed surviving
    /// the file by minutes. So the Trash lifecycle has to clear it.
    ///
    /// The record is pointed at a bundle outside the Trash on purpose. What
    /// `reconcileRegistrations` acts on is "a bundle this plan trashed that
    /// is no longer there", and the Trash itself cannot be used to stage
    /// that: registering anything under `~/.Trash` needs Full Disk Access to
    /// read it, which a `swift test` run does not have. So the journal — the
    /// record Brim itself keeps and the only input this reads — is pointed
    /// at a bundle the test can register and then remove.
    func testAVanishedTrashedBundleLosesItsRegistration() async throws {
        _ = try fixture.makeRegisteredAppBundle()
        _ = try fixture.makeAppFootprint()
        let identity = Identity(bundleID: fixture.harnessBundleID, name: fixture.runID)

        let service = makeService()
        let plan = try await service.plan(intent: PlanIntent(
            type: .uninstall,
            subjectIdentity: identity,
            requesterKind: "harness",
            requesterIdentity: NSUserName()
        ))
        let bundleStep = try XCTUnwrap(plan.steps.first { $0.executionPhase == .appBundle })

        let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
        try await service.apply(planId: plan.planId, token: token)

        // Stand a registered bundle where the journal will say the trashed
        // copy went, then record that in the journal.
        let standIn = try fixture.makeRegisteredAppBundle(suffix: "-asif-trashed")
        let journals = JournalStore(directoryURL: supportDirectory.appendingPathComponent("Journals"))
        let loaded = try await journals.load(planId: plan.planId)
        var journal = try XCTUnwrap(loaded)
        journal.stepTrashedURLs = [bundleStep.index: standIn]
        try await journals.write(entry: journal)

        try XCTSkipUnless(
            LaunchServicesRegistration
                .registeredApplicationURLs(forBundleID: fixture.harnessBundleID)
                .contains { $0.standardizedFileURL.path == standIn.standardizedFileURL.path },
            "Launch Services did not register the stand-in bundle"
        )

        // Nothing to reconcile while the bundle is still there: the record
        // is accurate, exactly as it is for an app sitting in the Trash.
        await service.reconcileRegistrations()
        XCTAssertTrue(
            LaunchServicesRegistration
                .registeredApplicationURLs(forBundleID: fixture.harnessBundleID)
                .contains { $0.standardizedFileURL.path == standIn.standardizedFileURL.path },
            "A registration for a bundle that exists must be left alone"
        )

        // Now it goes, the way emptying the Trash removes it.
        try FileManager.default.removeItem(at: standIn)
        await service.reconcileRegistrations()

        XCTAssertFalse(
            LaunchServicesRegistration
                .registeredApplicationURLs(forBundleID: fixture.harnessBundleID)
                .contains { $0.standardizedFileURL.path == standIn.standardizedFileURL.path },
            "macOS is still pointing at a bundle that no longer exists"
        )
    }
}
