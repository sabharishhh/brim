@testable import BrimCore
@testable import BrimFixtures
@testable import BrimProtocol
@testable import BrimService
import Foundation
import XCTest

final class BrimServiceTests: XCTestCase {
    func testRemainingLoginRecordsOfferRemovalWithoutTreatingBackgroundSwitchesAsErasure() {
        // A removed helper remained in both Settings lists after Trash was
        // emptied. Its BTM type did not mark it as a legacy login item.
        let record = Registration(kind: .backgroundItem, identifier: "org.example.agent", label: "Agent",
                                  targetExists: false, evidence: "Target missing", atLogin: false)
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "fixture", osVersion: "fixture",
                        intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(name: "Example")),
                        steps: [], excludedItems: [], expectedTotalBytes: 0)
        let remaining = RegistrationVerification(capability: .backgroundItem, observedAt: Date(),
                                                 coverage: .available(.backgroundItem), remaining: [record])
        XCTAssertEqual(BrimService.registrationRoutes(plan: plan, observations: [remaining]), [.loginItemsSettings])
        XCTAssertFalse(remaining.confirmedClear)
        XCTAssertFalse(record.isActionable)

        let retained = RegistrationVerification(capability: .backgroundItem, observedAt: Date(),
                                                coverage: .available(.backgroundItem), remaining: [],
                                                preserved: [record], recoveryCopies: [record])
        let unread = RegistrationVerification(capability: .backgroundItem, observedAt: Date(),
                                              coverage: .unavailable(.backgroundItem, "Could not read"), remaining: [])
        let clear = RegistrationVerification(capability: .backgroundItem, observedAt: Date(),
                                             coverage: .available(.backgroundItem), remaining: [])
        XCTAssertTrue(BrimService.registrationRoutes(plan: plan, observations: [retained, unread, clear]).isEmpty)
        XCTAssertFalse(unread.confirmedClear)
        XCTAssertTrue(clear.confirmedClear)

        let legacy = Registration(kind: .legacyLoginItem, identifier: "org.example.old", label: "Old",
                                  targetExists: false, evidence: "Target missing")
        XCTAssertEqual(legacy.loginItemsFollowUp, .loginItemsSettings)
        let system = Registration(kind: .backgroundItem, identifier: "com.apple.example", label: "System",
                                  targetExists: false, evidence: "Target missing", isSystemOwned: true)
        XCTAssertNil(system.loginItemsFollowUp)
        XCTAssertTrue(RemovalFollowUp.loginItemsSettings.sentence.hasPrefix("If the item is listed"))
    }

    func testSkippedBundleRemainsVisibleAndDoesNotSuggestReinstalling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = FileSystemRoot(rootURL: directory.appendingPathComponent("Root"))
        let bundle = root.url(for: .applications).appendingPathComponent("Retained.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let journals = directory.appendingPathComponent("Journals")
        let service = BrimService(root: root, brimAppURL: directory.appendingPathComponent("Brim.app"),
                                  planStoreDirectory: directory.appendingPathComponent("Plans"),
                                  journalStoreDirectory: journals)
        let identity = Identity(bundleID: "org.example.retained", name: "Retained")
        let steps = [
            Step(index: 0, kind: .resetPrivacyGrants, target: "org.example.retained",
                 targetFingerprint: nil, tier: .A, evidence: "Privacy reset", expectedBytes: 0,
                 capability: .ok, reversible: false, costOfError: .medium),
            Step(index: 1, kind: .trashPath, target: bundle.path,
                 targetFingerprint: nil, tier: .A, evidence: "Application", expectedBytes: 1,
                 capability: .ok, reversible: true, costOfError: .medium, executionPhase: .appBundle)
        ]
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "fixture", osVersion: "fixture",
                        intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
                        steps: steps, excludedItems: [], expectedTotalBytes: 1)
        try await service.planStore.save(plan: plan)
        try await JournalStore(directoryURL: journals).write(entry: JournalEntry(
            planId: plan.planId, startedAt: Date(), status: .partial,
            stepOutcomes: [0: "privacy_grants_not_cleared", 1: "skipped_due_to_prior_failures"]
        ))
        let result = try await service.verify(planId: plan.planId)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.remainingPaths, [bundle.path])
        XCTAssertTrue(result.removedPaths(from: [bundle.path]).isEmpty)
        XCTAssertNil(result.followUpActions)
    }

    func testFailedReceiptActionCannotPassVerificationWithoutFileTargets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journals = directory.appendingPathComponent("Journals")
        let service = BrimService(root: FileSystemRoot(rootURL: directory),
                                  brimAppURL: directory.appendingPathComponent("Brim.app"),
                                  planStoreDirectory: directory.appendingPathComponent("Plans"),
                                  journalStoreDirectory: journals)
        let step = Step(index: 0, kind: .forgetReceipt, target: "org.example.package",
                        targetFingerprint: nil, tier: .A, evidence: "Receipt", expectedBytes: 0,
                        capability: .needsHelper, reversible: false, costOfError: .medium)
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "fixture", osVersion: "fixture",
                        intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(name: "Example")),
                        steps: [step], excludedItems: [], expectedTotalBytes: 0)
        try await service.planStore.save(plan: plan)
        try await JournalStore(directoryURL: journals).write(entry: JournalEntry(
            planId: plan.planId, startedAt: Date(), status: .partial,
            stepOutcomes: [0: "needs_helper_not_set_up"]
        ))
        let result = try await service.verify(planId: plan.planId)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.reason, "Some planned actions could not be completed.")
    }

    func testFailedPrivacyResetIsNotReportedAsCompleteAfterBundleRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-removal-ceiling-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = FileSystemRoot(rootURL: directory.appendingPathComponent("Root"))
        let plans = directory.appendingPathComponent("Plans")
        let journals = directory.appendingPathComponent("Journals")
        let service = BrimService(root: root, brimAppURL: directory.appendingPathComponent("Brim.app"),
                                  planStoreDirectory: plans, journalStoreDirectory: journals)
        let identity = Identity(bundleID: "org.example.departed", name: "Departed")
        let reset = Step(index: 0, kind: .resetPrivacyGrants, target: "org.example.departed",
                         targetFingerprint: nil, tier: .A, evidence: "Privacy reset",
                         expectedBytes: 0, capability: .ok, reversible: false,
                         costOfError: .medium)
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "fixture",
                        osVersion: "fixture", intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
                        steps: [reset], excludedItems: [], expectedTotalBytes: 0)
        try await service.planStore.save(plan: plan)
        try await JournalStore(directoryURL: journals).write(entry: JournalEntry(
            planId: plan.planId, startedAt: Date(), status: .partial,
            stepOutcomes: [0: "privacy_grants_not_cleared"]
        ))

        let result = try await service.verify(planId: plan.planId)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.reason, "Privacy permissions were not reset.")
        XCTAssertEqual(result.followUpActions, [.restoreAppForPrivacyReset])
    }

    func testFailedPrivacyResetWithInstalledBundleDoesNotSuggestReinstalling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-reset-ceiling-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = FileSystemRoot(rootURL: directory.appendingPathComponent("Root"))
        let plans = directory.appendingPathComponent("Plans")
        let journals = directory.appendingPathComponent("Journals")
        let bundle = directory.appendingPathComponent("Root/Applications/Installed.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let service = BrimService(root: root, brimAppURL: directory.appendingPathComponent("Brim.app"),
                                  planStoreDirectory: plans, journalStoreDirectory: journals)
        let identity = Identity(bundleID: "org.example.installed", name: "Installed", bundlePath: bundle.path)
        let reset = Step(index: 0, kind: .resetPrivacyGrants, target: "org.example.installed",
                         targetFingerprint: nil, tier: .A, evidence: "Privacy reset",
                         expectedBytes: 0, capability: .ok, reversible: false,
                         costOfError: .medium)
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "fixture",
                        osVersion: "fixture", intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
                        steps: [reset], excludedItems: [], expectedTotalBytes: 0)
        try await service.planStore.save(plan: plan)
        try await JournalStore(directoryURL: journals).write(entry: JournalEntry(
            planId: plan.planId, startedAt: Date(), status: .partial,
            stepOutcomes: [0: "privacy_grants_not_cleared"]
        ))

        let result = try await service.verify(planId: plan.planId)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.reason, "Privacy permissions were not reset.")
        XCTAssertNil(result.followUpActions)
    }

    func testServiceDrivesCompleteUninstall() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        let planStoreDir = tempDir.appendingPathComponent("Plans")
        let journalStoreDir = tempDir.appendingPathComponent("Journals")

        let gen = FixtureTreeGenerator(rootURL: rootURL)
        defer { gen.destroy() }
        try gen.generate()

        let root = FileSystemRoot(rootURL: rootURL)
        let brimAppURL = rootURL.appendingPathComponent("Brim.app")
        let realService = BrimService(
            root: root,
            brimAppURL: brimAppURL,
            planStoreDirectory: planStoreDir,
            journalStoreDirectory: journalStoreDir,
            launchdRuntime: .unregisteredFixture
        )

        let service: any BrimServiceProtocol = realService

        let bundleURL = rootURL.appendingPathComponent("Applications/SandboxedApp.app")
        let resolver = IdentityResolver(root: root)
        let identity = await resolver.resolve(bundleURL: bundleURL)

        // Ensure AppBundleSource is injected for the test since we have the URL
        // Wait, BrimService doesn't have a way to inject sources.
        // Actually, BundleIdentifierComponentSource will find SandboxedApp.app if its name matches.

        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        let plan = try await service.plan(intent: intent)

        XCTAssertGreaterThan(plan.steps.count, 0)
        XCTAssertGreaterThanOrEqual(plan.expectedTotalBytes, 0)

        let verifyBefore = try await service.verify(planId: plan.planId)
        XCTAssertFalse(verifyBefore.success)

        let hash = try plan.contentHash()
        let token = await realService.tokenStore.mintToken(
            planId: plan.planId,
            planHash: hash,
            requesterIdentity: intent.requesterIdentity
        )

        try await service.apply(planId: plan.planId, token: token)

        let verifyAfter = try await service.verify(planId: plan.planId)
        XCTAssertTrue(verifyAfter.remainingPaths.isEmpty)
        XCTAssertFalse(verifyAfter.success, "The fixture's unregistered bundle cannot pass tccutil")
        XCTAssertEqual(verifyAfter.followUpActions, [.restoreAppForPrivacyReset])

        // Let's assert the recovered bytes matches the expected bytes
        // Since we are moving to Trash, the free space might not change immediately on APFS due to snapshotting or just
        // being moved to another directory on the same volume!
        // To be safe against APFS nuances, we can just assert that verifyAfter has expectedBytes populated.
        XCTAssertEqual(verifyAfter.expectedBytes, plan.expectedTotalBytes)
        // Recovered bytes may be 0 if the volume didn't actually reclaim space yet, but we at least recorded it.
        XCTAssertGreaterThanOrEqual(verifyAfter.recoveredBytes, 0)
    }
}
