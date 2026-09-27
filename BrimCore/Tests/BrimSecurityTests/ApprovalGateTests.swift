import XCTest
import Foundation
@testable import BrimCore
@testable import BrimProtocol
@testable import BrimService
@testable import BrimFixtures

/// The gate that makes Brim safe to give root to.
///
/// `requestApproval` used to mint a token outright whenever `ApprovalPolicy`
/// judged the plan reversible, which is nearly every plan. Inside the app
/// that was defensible: the review sheet had been read and a person had
/// pressed the button. Anywhere else there is no review sheet, so plan,
/// request, apply ran end to end with nobody involved. The product's whole
/// claim is that this cannot happen, so it is tested here rather than
/// asserted in a document.
final class ApprovalGateTests: XCTestCase {

    /// Counts how many times the gate asked for a fingerprint, without
    /// raising one. The real check puts a system dialog on screen and
    /// waits, which stopped the whole suite the first time these ran.
    actor PresenceSpy {
        private(set) var asks: [String] = []
        private var refusing = false

        func refuse() { refusing = true }
        private func record(_ reason: String) throws {
            asks.append(reason)
            if refusing {
                throw NSError(domain: "test", code: 403,
                              userInfo: [NSLocalizedDescriptionKey: "nobody is there"])
            }
        }

        nonisolated func check() -> PresenceCheck {
            PresenceCheck { reason in try await self.record(reason) }
        }
    }

    private func makeService(
        consent: ConsentSource? = nil,
        presence: PresenceCheck? = nil,
        automatedConsentAllowed: Bool = false
    ) throws -> (service: BrimService, gen: FixtureTreeGenerator, rootURL: URL, planDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = tempDir.appendingPathComponent("Root")
        let gen = FixtureTreeGenerator(rootURL: rootURL)
        try gen.generate()
        let planDir = tempDir.appendingPathComponent("Plans")
        let service = BrimService(
            root: FileSystemRoot(rootURL: rootURL),
            brimAppURL: rootURL.appendingPathComponent("Brim.app"),
            planStoreDirectory: planDir,
            journalStoreDirectory: tempDir.appendingPathComponent("Journals"),
            consent: consent,
            presence: presence ?? PresenceCheck { _ in },
            automatedConsentAllowed: automatedConsentAllowed
        )
        return (service, gen, rootURL, planDir)
    }

    private func plan(from service: BrimService, in rootURL: URL) async throws -> Plan {
        let bundleURL = rootURL.appendingPathComponent("Applications/SandboxedApp.app")
        let identity = await IdentityResolver(root: FileSystemRoot(rootURL: rootURL))
            .resolve(bundleURL: bundleURL)
        return try await service.plan(
            intent: PlanIntent(type: .uninstall, subjectIdentity: identity)
        )
    }

    // MARK: - Behaviour

    func testAskingIsNotApproving() async throws {
        let (service, gen, rootURL, _) = try makeService()
        defer { gen.destroy() }
        let plan = try await plan(from: service, in: rootURL)

        let receipt = try await service.requestApproval(
            planId: plan.planId, requesterIdentity: "agent"
        )

        XCTAssertTrue(receipt.awaitingHuman)
        XCTAssertEqual(receipt.planId, plan.planId)
        XCTAssertEqual(receipt.planHash, try plan.contentHash())
        XCTAssertFalse(receipt.summary.isEmpty, "A person has to be told what they are agreeing to")
    }

    func testAServiceWithNobodyToAskCannotApprove() async throws {
        // Any process that is not Brim's app. It runs the same code and
        // holds the same kind of object; what it has not got is a window.
        let (service, gen, rootURL, _) = try makeService(consent: nil)
        defer { gen.destroy() }
        let plan = try await plan(from: service, in: rootURL)
        let receipt = try await service.requestApproval(planId: plan.planId, requesterIdentity: "agent")

        do {
            _ = try await service.grantApproval(for: receipt)
            XCTFail("A service with no way to ask a person granted an approval")
        } catch let error as ApprovalError {
            XCTAssertEqual(error, .noHumanToAsk)
        }
    }

    func testANoIsRespected() async throws {
        let (service, gen, rootURL, _) = try makeService(consent: ConsentSource { _ in false })
        defer { gen.destroy() }
        let plan = try await plan(from: service, in: rootURL)
        let receipt = try await service.requestApproval(planId: plan.planId, requesterIdentity: "user")

        do {
            _ = try await service.grantApproval(for: receipt)
            XCTFail("Declining produced a token anyway")
        } catch let error as ApprovalError {
            XCTAssertEqual(error, .declined)
        }
    }

    func testAReceiptIsSpentOnce() async throws {
        let (service, gen, rootURL, _) = try makeService(consent: ConsentSource { _ in true })
        defer { gen.destroy() }
        let plan = try await plan(from: service, in: rootURL)
        let receipt = try await service.requestApproval(planId: plan.planId, requesterIdentity: "user")

        _ = try await service.grantApproval(for: receipt)
        do {
            _ = try await service.grantApproval(for: receipt)
            XCTFail("The same request was answered twice")
        } catch let error as ApprovalError {
            XCTAssertEqual(error, .requestNotPending)
        }
    }

    func testAForgedReceiptIsNotPending() async throws {
        let (service, gen, rootURL, _) = try makeService(consent: ConsentSource { _ in true })
        defer { gen.destroy() }
        let plan = try await plan(from: service, in: rootURL)

        // Shaped exactly like a real one, and never asked for.
        let forged = ApprovalRequestReceipt(
            requestId: UUID(), planId: plan.planId, planHash: try plan.contentHash(),
            requester: "agent", requestedAt: Date(),
            expiresAt: Date().addingTimeInterval(300),
            summary: "Remove something.", awaitingHuman: true
        )

        do {
            _ = try await service.grantApproval(for: forged)
            XCTFail("A receipt nobody issued was honoured")
        } catch let error as ApprovalError {
            XCTAssertEqual(error, .requestNotPending)
        }
    }

    func testAPlanEditedAfterTheRequestLosesTheApproval() async throws {
        let (service, gen, rootURL, planDir) = try makeService(consent: ConsentSource { _ in true })
        defer { gen.destroy() }
        let original = try await plan(from: service, in: rootURL)
        let receipt = try await service.requestApproval(
            planId: original.planId, requesterIdentity: "user"
        )

        // Same identifier, different contents: what the person was shown is
        // no longer what would happen.
        let swapped = Plan(
            planId: original.planId, createdAt: original.createdAt,
            engineVersion: original.engineVersion, osVersion: original.osVersion,
            intent: original.intent, steps: Array(original.steps.dropLast()),
            excludedItems: original.excludedItems, expectedTotalBytes: original.expectedTotalBytes
        )
        // Written straight to the store's directory: `PlanStore.save`
        // refuses to overwrite, which is correct and is the reason this has
        // to go around it to stage the attack.
        try swapped.canonicalData().write(
            to: planDir.appendingPathComponent("\(original.planId.uuidString).json"),
            options: .atomic
        )

        do {
            _ = try await service.grantApproval(for: receipt)
            XCTFail("An approval survived the plan changing underneath it")
        } catch let error as ApprovalError {
            XCTAssertEqual(error, .planChangedSinceRequest)
        }
    }

    func testAnXPCClientHasNoWayToApprove() async throws {
        let (service, gen, _, _) = try makeService(consent: ConsentSource { _ in true })
        defer { gen.destroy() }

        let listener = NSXPCListener.anonymous()
        let delegate = BrimXPCListenerDelegate(service: service, accepting: .sameProcessAnonymous)
        listener.delegate = delegate
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: BrimXPCProtocol.self)
        let client = try BrimXPCClient(connection: connection, expecting: .sameProcessAnonymous)

        XCTAssertNil(
            client as Any as? ApprovalGranting,
            "Anything on the far side of a connection must have no method that mints a token"
        )
    }

    func testTheOneRouteToApplyRefusesWhenNothingCanAsk() async throws {
        let (service, gen, rootURL, _) = try makeService(consent: nil)
        defer { gen.destroy() }
        let plan = try await plan(from: service, in: rootURL)

        do {
            try await service.approveAndApply(planId: plan.planId, requesterIdentity: "agent")
            XCTFail("A plan was applied with nobody to approve it")
        } catch let error as ApprovalError {
            XCTAssertEqual(error, .noHumanToAsk)
        }
    }

    /// The app's own configuration, with the debug shortcut switched off.
    ///
    /// The gate has to refuse a service with no window and let Brim
    /// through, and a test that only proves the first half would be
    /// satisfied by a gate that refuses everybody.
    func testTheAppItselfCanStillApplyAnApprovedRemoval() async throws {
        let (service, gen, rootURL, _) = try makeService(consent: ConsentSource { _ in true })
        defer { gen.destroy() }
        let plan = try await plan(from: service, in: rootURL)
        XCTAssertGreaterThan(plan.steps.count, 0)

        try await service.approveAndApply(planId: plan.planId, requesterIdentity: "user")

        let verification = try await service.verify(planId: plan.planId)
        XCTAssertTrue(verification.remainingPaths.isEmpty, "The app did not remove the approved files")
        XCTAssertFalse(verification.success, "The fixture's unregistered bundle cannot pass tccutil")
        XCTAssertEqual(verification.followUpActions, [.restoreAppForPrivacyReset])
    }

    func testADestructivePlanStillCostsAFingerprint() async throws {
        // Consent and presence are different claims. The review sheet says
        // the person agreed; the fingerprint says somebody is at the
        // machine now rather than software driving the app. A plan that
        // destroys something nothing can restore needs both.
        let spy = PresenceSpy()
        let (service, gen, rootURL, _) = try makeService(
            consent: ConsentSource { _ in true }, presence: spy.check()
        )
        defer { gen.destroy() }
        let plan = try await plan(from: service, in: rootURL)
        try XCTSkipIf(plan.stepsWarrantingHumanPresence.isEmpty,
                      "The fixture plan destroys nothing, so there is nothing to prove here")

        let receipt = try await service.requestApproval(planId: plan.planId, requesterIdentity: "user")
        _ = try await service.grantApproval(for: receipt)

        let asks = await spy.asks
        XCTAssertEqual(asks.count, 1, "A destructive plan has to ask once, and only once")
        XCTAssertFalse(asks[0].isEmpty)
        XCTAssertFalse(asks[0].hasSuffix("."),
                       "macOS renders this as \"Brim is trying to ___\"")
        XCTAssertEqual(asks[0], asks[0].prefix(1).lowercased() + asks[0].dropFirst(),
                       "It is a lowercase verb phrase, not a sentence")
    }

    func testNobodyAtTheMachineMeansNoToken() async throws {
        let spy = PresenceSpy()
        await spy.refuse()
        let (service, gen, rootURL, _) = try makeService(
            consent: ConsentSource { _ in true }, presence: spy.check()
        )
        defer { gen.destroy() }
        let plan = try await plan(from: service, in: rootURL)
        try XCTSkipIf(plan.stepsWarrantingHumanPresence.isEmpty,
                      "The fixture plan destroys nothing, so presence is never asked for")

        let receipt = try await service.requestApproval(planId: plan.planId, requesterIdentity: "user")
        do {
            _ = try await service.grantApproval(for: receipt)
            XCTFail("A failed fingerprint still produced a token")
        } catch {
            XCTAssertEqual((error as NSError).code, 403)
        }
    }

    // MARK: - Shape

    /// T-1.12's acceptance criterion, as a test rather than as a promise.
    func testOnlyOneFunctionInTheProductProducesAToken() throws {
        let allowed: [String: Set<String>] = [
            // The mint itself.
            "TokenStore.swift": ["mintToken"],
            // The declaration of the channel a human decision travels along.
            "ApprovalToken.swift": ["grantApproval"],
            // Its single implementation.
            "BrimService.swift": ["grantApproval"],
        ]

        var offenders: [String] = []
        for file in Self.productSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                guard line.contains("-> ApprovalToken"), line.contains("func ") else { continue }
                let permitted = allowed[file.lastPathComponent] ?? []
                guard permitted.contains(where: { line.contains("func \($0)") }) else {
                    offenders.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                    continue
                }
            }
        }

        XCTAssertEqual(
            offenders, [],
            "Something new returns an ApprovalToken. There is meant to be one mint, reached "
            + "only after a person has answered. Add it to the allowed list only if that is "
            + "still true of it."
        )
    }

    func testNothingButTheGateCallsTheMint() throws {
        var callers: [String] = []
        for file in Self.productSources() where file.lastPathComponent != "TokenStore.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("mintToken(") {
                callers.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertEqual(callers.count, 1, "Expected exactly one call to mintToken, found: \(callers)")
        XCTAssertTrue(
            callers.first?.hasPrefix("BrimService.swift") ?? false,
            "The mint moved out of the approval gate: \(callers)"
        )
    }

    func testTheServiceProtocolCannotHandBackAToken() throws {
        let sources = Self.repositoryRoot().appendingPathComponent("BrimCore/Sources/BrimProtocol")
        for name in ["BrimServiceProtocol.swift", "BrimXPCProtocol.swift"] {
            let text = try String(
                contentsOf: sources.appendingPathComponent(name), encoding: .utf8
            )
            for line in text.split(separator: "\n") where line.contains("func ") {
                XCTAssertFalse(
                    line.contains("-> ApprovalToken"),
                    "\(name) offers a method that produces a token. Every adapter can reach "
                    + "this protocol, so nothing on it may."
                )
            }
        }
    }

    // MARK: - Helpers

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BrimSecurityTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BrimCore
            .deletingLastPathComponent()   // repo
    }

    /// Everything that ships: the package sources and the app target. Tests
    /// are excluded on purpose, because a test reaching past the gate to set
    /// up a fixture is not a way in for anybody else.
    private static func productSources() -> [URL] {
        let root = repositoryRoot()
        var files: [URL] = []
        for directory in ["BrimCore/Sources", "Brim"] {
            let url = root.appendingPathComponent(directory)
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            while let entry = walker?.nextObject() as? URL {
                if entry.pathExtension == "swift" { files.append(entry) }
            }
        }
        return files
    }
}
