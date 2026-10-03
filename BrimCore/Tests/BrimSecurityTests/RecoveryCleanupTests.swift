import BrimCore
import BrimProtocol
@testable import BrimService
import Testing
import XCTest

final class RecoveryCleanupTests: XCTestCase {
    private actor AuthenticationCounts {
        var starts = 0
        var stops = 0
        var presenceChecks = 0
        func start() -> String? {
            starts += 1; return nil
        }

        func stop() {
            stops += 1
        }

        func prove() {
            presenceChecks += 1
        }

        func counts() -> [Int] {
            [starts, stops, presenceChecks]
        }
    }

    private actor Copies {
        var copies: [RecoveryCopy]
        var calls = 0
        init(_ copies: [RecoveryCopy]) {
            self.copies = copies
        }

        func read() -> [RecoveryCopy] {
            copies
        }

        func remove(_ path: String, fingerprint: TargetFingerprint) -> String? {
            calls += 1
            guard copies.contains(where: { $0.path == path && $0.fingerprint == fingerprint }) else {
                return "Changed copy"
            }
            copies.removeAll { $0.path == path }
            return nil
        }
    }

    private func copy(_ name: String) -> RecoveryCopy {
        RecoveryCopy(path: RecoveryCopy.directory + "/2026-09-28T09-12-35Z/LaunchDaemons/" + name,
                     name: name, bundleID: nil, sizeBytes: 12, sizeIsKnown: true,
                     fingerprint: TargetFingerprint(dev: 1, ino: 42, mtime: Date(timeIntervalSince1970: 123)))
    }

    private func service(at directory: URL) -> BrimService {
        BrimService(root: FileSystemRoot(rootURL: directory), brimAppURL: directory.appendingPathComponent("Brim.app"),
                    planStoreDirectory: directory.appendingPathComponent("Plans"),
                    journalStoreDirectory: directory.appendingPathComponent("Journals"))
    }

    func testSelectedRecoveryUsesOneReviewedPermanentPlanAndLeavesOtherCopies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = copy("com.example.selected.plist")
        let other = copy("com.example.other.plist")
        let store = Copies([selected, other])
        let service = service(at: directory)
        await service.useRecoveryCopies(reader: { await store.read() }, remover: { path, fingerprint in
            await store.remove(path, fingerprint: fingerprint)
        })
        let intent = PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: nil, name: "Leftovers"),
                                specificTargets: [URL(fileURLWithPath: selected.path)])
        let plan = try await service.plan(intent: intent)
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first?.effectiveDisposition, .delete)
        XCTAssertEqual(plan.steps.first?.targetFingerprint, selected.fingerprint)
        XCTAssertEqual(plan.stepsWarrantingHumanPresence.count, 1)
        XCTAssertEqual(plan.setAsideBytes, 0)
        let token = try await service.tokenStore.mintToken(planId: plan.planId, planHash: plan.contentHash(),
                                                           requesterIdentity: intent.requesterIdentity)
        try await service.apply(planId: plan.planId, token: token)
        let result = try await service.verify(planId: plan.planId)
        XCTAssertTrue(result.success, result.reason ?? "")
        let remaining = await store.read()
        XCTAssertEqual(remaining, [other])
        let calls = await store.calls
        XCTAssertEqual(calls, 1)
    }

    func testUnlistedRecoveryTargetCannotEnterPlan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = service(at: directory)
        await service.useRecoveryCopies(reader: { [] }, remover: nil)
        do {
            _ = try await service.plan(intent: PlanIntent(
                type: .uninstall, subjectIdentity: Identity(bundleID: nil, name: "Leftovers"),
                specificTargets: [URL(fileURLWithPath: copy("missing.plist").path)]
            ))
            XCTFail("A caller-supplied recovery path must be independently listed by the helper.")
        } catch {}
    }

    func testAdministratorAuthenticationCoversPresenceAndOnlyOnePendingApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authentication = AuthenticationCounts()
        let selected = copy("selected.plist")
        let store = Copies([selected])
        let service = BrimService(
            root: FileSystemRoot(rootURL: directory), brimAppURL: directory.appendingPathComponent("Brim.app"),
            planStoreDirectory: directory.appendingPathComponent("Plans"),
            journalStoreDirectory: directory.appendingPathComponent("Journals"),
            consent: ConsentSource { _ in true },
            presence: PresenceCheck { _ in await authentication.prove() }, automatedConsentAllowed: false
        )
        await service.usePrivilegedBatch(begin: { await authentication.start() },
                                         end: { await authentication.stop() })
        await service.useRecoveryCopies(reader: { await store.read() }, remover: { path, fingerprint in
            await store.remove(path, fingerprint: fingerprint)
        })
        let plan = try await service.plan(intent: PlanIntent(
            type: .uninstall, subjectIdentity: Identity(bundleID: nil, name: "Leftovers"),
            specificTargets: [URL(fileURLWithPath: selected.path)]
        ))
        let receipt = try await service.requestApproval(planId: plan.planId,
                                                        requesterIdentity: plan.intent.requesterIdentity)
        let duplicate = try await service.requestApproval(planId: plan.planId,
                                                          requesterIdentity: plan.intent.requesterIdentity)
        let token = try await service.grantApproval(for: receipt)
        do {
            _ = try await service.grantApproval(for: duplicate)
            XCTFail("A second approval must not retain another administrator batch for the same plan.")
        } catch {}
        try await service.apply(planId: plan.planId, token: token)
        let executingCounts = await authentication.counts()
        XCTAssertEqual(executingCounts, [1, 0, 0], "Keep authorization for the immediate verification.")
        let result = try await service.verify(planId: plan.planId)
        XCTAssertTrue(result.success, result.reason ?? "")
        let counts = await authentication.counts()
        XCTAssertEqual(counts, [1, 1, 0])
        let remaining = await store.read()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCachedReviewCannotProveFreshAbsence() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = copy("selected.plist")
        let service = service(at: directory)
        await service.useRecoveryCopies(reader: { [] }, remover: nil)
        await service.useRecoveryVerifier {
            throw NSError(domain: "Fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Administrator process has ended."])
        }
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
                        intent: PlanIntent(type: .uninstall,
                                           subjectIdentity: Identity(bundleID: nil, name: "Leftovers")),
                        steps: [], excludedItems: [], expectedTotalBytes: 0).addingRecoveryRemoval([selected])
        let observations = await service.recoveryPresence(for: plan)
        XCTAssertEqual(observations[selected.path], .unknown("Administrator process has ended."))
    }

    func testRecoveryIdentifierNeverAcceptsItsParentsOrTraversal() {
        XCTAssertNil(RecoveryCopy.identifier(for: RecoveryCopy.directory))
        XCTAssertNil(RecoveryCopy.identifier(for: RecoveryCopy.directory + "/stamp/source/../outside"))
        XCTAssertNil(RecoveryCopy.identifier(for: RecoveryCopy.directory + "/stamp/source"))
        XCTAssertNotNil(RecoveryCopy.identifier(for: copy("item.plist").path))
    }
}

struct RecoveryRegistrationTests {
    /// Protected cleanup removed both selected files but reported a failed
    /// unregister because the reviewed bundle identifier was lost from the plan.
    @Test func recoveryRegistrationRetainsItsIdentifierAndChecksOnlyItsPath() throws {
        let path = RecoveryCopy.directory + "/stamp/Applications/Example.app"
        let copy = RecoveryCopy(path: path, name: "Example.app", bundleID: "org.example.app",
                                sizeBytes: 0, sizeIsKnown: false,
                                fingerprint: TargetFingerprint(dev: 1, ino: 42, mtime: Date()))
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
                        intent: PlanIntent(type: .uninstall,
                                           subjectIdentity: Identity(name: "Leftovers")),
                        steps: [], excludedItems: [], expectedTotalBytes: 0).addingRecoveryRemoval([copy])
        let step = try #require(plan.steps.first { $0.kind == .unregisterLaunchServices })
        #expect(step.registrationBundleID == copy.bundleID)
        let decoded = try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step))
        #expect(decoded.registrationBundleID == copy.bundleID)
        let alreadyGone = try Executor.componentIsAlreadyUnregistered(step: step, plan: plan) { identifier in
            #expect(identifier == copy.bundleID)
            return [URL(fileURLWithPath: "/Applications/Example.app")]
        }
        #expect(alreadyGone)
        #expect(try !Executor.componentIsAlreadyUnregistered(step: step, plan: plan) { _ in
            [URL(fileURLWithPath: path)]
        })
        #expect(throws: (any Error).self) {
            try Executor.componentIsAlreadyUnregistered(step: step, plan: plan) { _ in
                throw NSError(domain: "Fixture", code: 1)
            }
        }
    }
}
