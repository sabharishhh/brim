@testable import BrimCore
@testable import BrimProtocol
@testable import BrimService
import XCTest

/// A row ticked by hand in the uninstall sheet, all the way through the gate.
///
/// `apply` does not trust the plan it is given. It builds the plan again from
/// the stored intent and refuses unless every step and fingerprint matches,
/// so a person's choice that lived anywhere but the intent would make every
/// such removal fail its own check. And the approval is bound to the plan's
/// hash, which covers the intent, so the choice is part of what was approved.
///
/// The identity has no bundle identifier and no bundle on disk on purpose:
/// that keeps the privacy reset and the Launch Services retraction out of the
/// plan, so nothing here reaches past the fixture tree into this Mac's own
/// databases.
final class TickedByHandFlowTests: XCTestCase {
    private var tempDir: URL!
    private var rootURL: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("ticked-flow-\(UUID().uuidString)")
        rootURL = tempDir.appendingPathComponent("Root")
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: tempDir)
    }

    private func makeService() -> BrimService {
        BrimService(
            root: FileSystemRoot(rootURL: rootURL),
            brimAppURL: rootURL.appendingPathComponent("Applications/Brim.app"),
            planStoreDirectory: tempDir.appendingPathComponent("Plans"),
            journalStoreDirectory: tempDir.appendingPathComponent("Journals")
        )
    }

    private var home: URL {
        rootURL.appendingPathComponent("Users/\(NSUserName())")
    }

    /// Found only through the name the application gives itself, so Tier C
    /// and left unticked, which is exactly Visual Studio Code's
    /// `Application Support/Code`.
    private func makeSupportFolder() throws -> URL {
        let folder = home.appendingPathComponent("Library/Application Support/Studio")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2048).write(to: folder.appendingPathComponent("state.db"))
        return folder
    }

    private let identity = Identity(bundleID: nil, name: "Editor", bundleName: "Studio")

    private func intent(ticking paths: [String]? = nil) -> PlanIntent {
        PlanIntent(
            type: .uninstall, subjectIdentity: identity,
            requesterKind: "ui", requesterIdentity: "test-user", tickedByHand: paths
        )
    }

    /// **The whole point.** Found, offered, ticked, approved, rebuilt by
    /// `apply` from the intent, and removed.
    func testARowTickedByHandSurvivesTheGateAndIsRemoved() async throws {
        let support = try makeSupportFolder()
        let service = makeService()

        let offered = try await service.plan(intent: intent())
        let row = try XCTUnwrap(
            offered.excludedItems.first { $0.target == support.path },
            "The folder was not found at all, so there was nothing to offer."
        )
        XCTAssertEqual(row.canBeTickedByHand, true, "Found, and not offered to the person.")
        XCTAssertFalse(offered.steps.contains { $0.target == support.path }, "Ticked unasked.")

        let ticked = try await service.plan(intent: intent(ticking: [row.target]))
        XCTAssertTrue(ticked.steps.contains { $0.target == support.path })

        let token = try await service.approvedToken(planId: ticked.planId, requester: "test-user")
        do {
            try await service.apply(planId: ticked.planId, token: token)
        } catch {
            XCTFail(
                "Apply refused a plan with a hand-ticked row: \(error). It rebuilds the plan from "
                    + "the intent, so the choice has to be on the intent or this always fails."
            )
        }

        XCTAssertFalse(
            fileManager.fileExists(atPath: support.path),
            "The person ticked it, approved it, and it is still there."
        )
    }

    /// Naming a path the evidence engine did not find does not put it in an
    /// uninstall, however the intent arrives. Checked through the gate as
    /// well as in the planner, because the gate is where it would matter.
    func testAPathTheEngineDidNotFindSurvivesAnApprovedUninstall() async throws {
        let support = try makeSupportFolder()
        let documents = home.appendingPathComponent("Documents")
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        let thesis = documents.appendingPathComponent("Thesis.md")
        try Data("the person's own work".utf8).write(to: thesis)

        let service = makeService()
        let planned = try await service.plan(intent: intent(ticking: [support.path, thesis.path]))
        XCTAssertFalse(planned.steps.contains { $0.target == thesis.path })

        let token = try await service.approvedToken(planId: planned.planId, requester: "test-user")
        try await service.apply(planId: planned.planId, token: token)

        XCTAssertTrue(
            fileManager.fileExists(atPath: thesis.path),
            "A document nothing traced to this application was removed by an uninstall."
        )
        XCTAssertFalse(fileManager.fileExists(atPath: support.path))
    }
}
